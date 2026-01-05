// Media Player with libmpv and custom stream protocol
//
// This module provides a media player that reads from an in-memory ring buffer
// instead of files, enabling zero-copy streaming from MoQ to the player.
//
// Architecture:
// - Ring buffer holds incoming fMP4 segments
// - Custom "moqbuffer://" protocol registered with mpv
// - mpv reads from ring buffer via stream callbacks
// - Dart writes data to buffer via FFI
// - Video rendered via mpv render API to OpenGL texture (optional)

use libmpv2_sys::*;
use parking_lot::{Mutex, Condvar};
use std::collections::VecDeque;
use std::ffi::{CStr, CString};
use std::os::raw::{c_void, c_char, c_int};
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicI32, Ordering};

/// Ring buffer for streaming media data
pub struct MediaBuffer {
    data: Mutex<VecDeque<u8>>,
    condvar: Condvar,
    eof: AtomicBool,
    total_written: AtomicU64,
    total_read: AtomicU64,
    max_size: usize,
}

impl MediaBuffer {
    pub fn new(max_size: usize) -> Self {
        Self {
            data: Mutex::new(VecDeque::with_capacity(max_size)),
            condvar: Condvar::new(),
            eof: AtomicBool::new(false),
            total_written: AtomicU64::new(0),
            total_read: AtomicU64::new(0),
            max_size,
        }
    }

    /// Write data to the buffer
    /// Returns number of bytes written (may be less than requested if buffer is full)
    pub fn write(&self, data: &[u8]) -> usize {
        let mut buffer = self.data.lock();
        let available = self.max_size.saturating_sub(buffer.len());
        let to_write = data.len().min(available);

        for &byte in &data[..to_write] {
            buffer.push_back(byte);
        }

        self.total_written.fetch_add(to_write as u64, Ordering::Relaxed);

        // Notify waiting readers
        self.condvar.notify_all();

        to_write
    }

    /// Read data from the buffer (blocking)
    /// Returns 0 on EOF, -1 on error
    pub fn read(&self, buf: &mut [u8]) -> i64 {
        let mut buffer = self.data.lock();

        // Wait for data if buffer is empty
        while buffer.is_empty() && !self.eof.load(Ordering::Relaxed) {
            // Wait with timeout to allow checking EOF periodically
            let result = self.condvar.wait_for(&mut buffer, std::time::Duration::from_millis(100));
            if result.timed_out() {
                // Check EOF again after timeout
                if self.eof.load(Ordering::Relaxed) && buffer.is_empty() {
                    return 0; // EOF
                }
                continue;
            }
        }

        if buffer.is_empty() && self.eof.load(Ordering::Relaxed) {
            return 0; // EOF
        }

        // Read available data
        let to_read = buf.len().min(buffer.len());
        for i in 0..to_read {
            buf[i] = buffer.pop_front().unwrap();
        }

        self.total_read.fetch_add(to_read as u64, Ordering::Relaxed);

        to_read as i64
    }

    /// Mark end of stream
    pub fn set_eof(&self) {
        self.eof.store(true, Ordering::Relaxed);
        self.condvar.notify_all();
    }

    /// Reset the buffer
    pub fn reset(&self) {
        let mut buffer = self.data.lock();
        buffer.clear();
        self.eof.store(false, Ordering::Relaxed);
        self.total_written.store(0, Ordering::Relaxed);
        self.total_read.store(0, Ordering::Relaxed);
    }

    /// Get buffer statistics
    pub fn stats(&self) -> (usize, u64, u64) {
        let buffer = self.data.lock();
        (
            buffer.len(),
            self.total_written.load(Ordering::Relaxed),
            self.total_read.load(Ordering::Relaxed),
        )
    }
}

/// Stream context for mpv callbacks
struct StreamContext {
    buffer: Arc<MediaBuffer>,
    position: AtomicU64,
}

/// Video output mode
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum VideoOutput {
    /// Native window (desktop only)
    Window,
    /// No video output (audio only)
    Null,
    /// GPU texture (for Flutter integration - not yet implemented)
    Texture,
}

/// Media player instance
pub struct MediaPlayer {
    mpv: *mut mpv_handle,
    buffer: Arc<MediaBuffer>,
    is_playing: AtomicBool,
    stream_ctx: Option<Box<StreamContext>>,
    video_output: VideoOutput,
    video_width: AtomicI32,
    video_height: AtomicI32,
}

// Safety: MediaPlayer is Send because mpv_handle access is synchronized
unsafe impl Send for MediaPlayer {}
unsafe impl Sync for MediaPlayer {}

impl MediaPlayer {
    /// Create a new media player
    pub fn new() -> Result<Self, String> {
        Self::with_video_output(VideoOutput::Window)
    }

    /// Create a new media player with specific video output mode
    pub fn with_video_output(video_output: VideoOutput) -> Result<Self, String> {
        unsafe {
            eprintln!("[mpv] Creating mpv instance with {:?} output", video_output);

            let mpv = mpv_create();
            if mpv.is_null() {
                eprintln!("[mpv] mpv_create() returned null!");
                return Err("Failed to create mpv instance".to_string());
            }
            eprintln!("[mpv] mpv_create() succeeded");

            // Configure video output
            match video_output {
                VideoOutput::Window => {
                    // Use default video output (auto-detect)
                    // mpv will create its own window
                    eprintln!("[mpv] Using default window output");
                }
                VideoOutput::Null => {
                    eprintln!("[mpv] Setting vo=null");
                    Self::set_option_string(mpv, "vo", "null")?;
                }
                VideoOutput::Texture => {
                    // For texture output, we need to set up render context
                    // This requires OpenGL initialization from the host
                    eprintln!("[mpv] Setting vo=libmpv");
                    Self::set_option_string(mpv, "vo", "libmpv")?;
                }
            }

            // Configure for low latency streaming
            Self::configure_for_streaming(mpv)?;

            // Initialize mpv
            eprintln!("[mpv] Calling mpv_initialize()");
            let ret = mpv_initialize(mpv);
            if ret < 0 {
                eprintln!("[mpv] mpv_initialize() failed with error: {}", ret);
                mpv_destroy(mpv);
                return Err(format!("Failed to initialize mpv: {}", ret));
            }
            eprintln!("[mpv] mpv_initialize() succeeded");

            let buffer = Arc::new(MediaBuffer::new(16 * 1024 * 1024)); // 16MB buffer

            Ok(Self {
                mpv,
                buffer,
                is_playing: AtomicBool::new(false),
                stream_ctx: None,
                video_output,
                video_width: AtomicI32::new(0),
                video_height: AtomicI32::new(0),
            })
        }
    }

    /// Configure mpv for low-latency streaming
    unsafe fn configure_for_streaming(mpv: *mut mpv_handle) -> Result<(), String> {
        // Disable caching for live playback
        Self::set_option_string(mpv, "cache", "no")?;
        Self::set_option_string(mpv, "cache-pause", "no")?;

        // Low latency profile
        Self::set_option_string(mpv, "profile", "low-latency")?;

        // Don't wait for full file
        Self::set_option_string(mpv, "demuxer-readahead-secs", "0.5")?;

        // Untimed mode for live streams
        Self::set_option_string(mpv, "untimed", "yes")?;

        // Reduce audio buffer
        Self::set_option_string(mpv, "audio-buffer", "0.1")?;

        // Enable verbose logging for debugging
        Self::set_option_string(mpv, "msg-level", "all=v")?;

        Ok(())
    }

    unsafe fn set_option_string(mpv: *mut mpv_handle, name: &str, value: &str) -> Result<(), String> {
        let name_cstr = CString::new(name).map_err(|e| e.to_string())?;
        let value_cstr = CString::new(value).map_err(|e| e.to_string())?;

        let ret = mpv_set_option_string(mpv, name_cstr.as_ptr(), value_cstr.as_ptr());
        if ret < 0 {
            log::warn!("Failed to set mpv option {}={}: {}", name, value, ret);
        }
        Ok(())
    }

    /// Register the custom stream protocol
    pub fn register_protocol(&mut self) -> Result<(), String> {
        unsafe {
            eprintln!("[mpv] Registering moqbuffer:// protocol");

            // Create stream context
            let ctx = Box::new(StreamContext {
                buffer: Arc::clone(&self.buffer),
                position: AtomicU64::new(0),
            });

            let ctx_ptr = Box::into_raw(ctx) as *mut c_void;

            let protocol = CString::new("moqbuffer").map_err(|e| e.to_string())?;

            let ret = mpv_stream_cb_add_ro(
                self.mpv,
                protocol.as_ptr(),
                ctx_ptr,
                Some(stream_open_callback),
            );

            if ret < 0 {
                eprintln!("[mpv] mpv_stream_cb_add_ro failed with error: {}", ret);
                // Reclaim the box to avoid leak
                let _ = Box::from_raw(ctx_ptr as *mut StreamContext);
                return Err(format!("Failed to register stream protocol: {}", ret));
            }

            // Store context so we can clean it up later
            self.stream_ctx = Some(Box::from_raw(ctx_ptr as *mut StreamContext));

            eprintln!("[mpv] Protocol registered successfully");
            log::info!("Registered moqbuffer:// protocol");
            Ok(())
        }
    }

    /// Start playback from the buffer
    pub fn play(&self) -> Result<(), String> {
        unsafe {
            eprintln!("[mpv] play() called, loading moqbuffer://stream");

            let cmd_loadfile = CString::new("loadfile").unwrap();
            let uri = CString::new("moqbuffer://stream").unwrap();

            let mut args: [*const c_char; 3] = [
                cmd_loadfile.as_ptr(),
                uri.as_ptr(),
                ptr::null(),
            ];

            let ret = mpv_command(self.mpv, args.as_mut_ptr());
            if ret < 0 {
                eprintln!("[mpv] loadfile failed with error: {}", ret);
                return Err(format!("Failed to load stream: {}", ret));
            }

            self.is_playing.store(true, Ordering::Relaxed);
            eprintln!("[mpv] loadfile command sent successfully");
            log::info!("Started playback from moqbuffer://stream");
            Ok(())
        }
    }

    /// Pause playback
    pub fn pause(&self) -> Result<(), String> {
        self.set_property_bool("pause", true)
    }

    /// Resume playback
    pub fn resume(&self) -> Result<(), String> {
        self.set_property_bool("pause", false)
    }

    /// Stop playback
    pub fn stop(&self) -> Result<(), String> {
        unsafe {
            let cmd = CString::new("stop").unwrap();
            let mut args: [*const c_char; 2] = [cmd.as_ptr(), ptr::null()];

            let ret = mpv_command(self.mpv, args.as_mut_ptr());
            if ret < 0 {
                return Err(format!("Failed to stop: {}", ret));
            }

            self.is_playing.store(false, Ordering::Relaxed);
            Ok(())
        }
    }

    fn set_property_bool(&self, name: &str, value: bool) -> Result<(), String> {
        unsafe {
            let name_cstr = CString::new(name).map_err(|e| e.to_string())?;
            let value_str = if value { "yes" } else { "no" };
            let value_cstr = CString::new(value_str).unwrap();

            let ret = mpv_set_property_string(self.mpv, name_cstr.as_ptr(), value_cstr.as_ptr());
            if ret < 0 {
                return Err(format!("Failed to set property {}: {}", name, ret));
            }
            Ok(())
        }
    }

    /// Write media data to the buffer
    pub fn write_data(&self, data: &[u8]) -> usize {
        self.buffer.write(data)
    }

    /// Signal end of stream
    pub fn end_stream(&self) {
        self.buffer.set_eof();
    }

    /// Get buffer statistics (buffered_bytes, total_written, total_read)
    pub fn buffer_stats(&self) -> (usize, u64, u64) {
        self.buffer.stats()
    }

    /// Check if playing
    pub fn is_playing(&self) -> bool {
        self.is_playing.load(Ordering::Relaxed)
    }

    /// Process events (should be called periodically)
    pub fn process_events(&self) {
        unsafe {
            loop {
                let event = mpv_wait_event(self.mpv, 0.0);
                if (*event).event_id == mpv_event_id_MPV_EVENT_NONE {
                    break;
                }

                match (*event).event_id {
                    mpv_event_id_MPV_EVENT_LOG_MESSAGE => {
                        let msg = (*event).data as *mut mpv_event_log_message;
                        if !msg.is_null() {
                            let text = CStr::from_ptr((*msg).text).to_string_lossy();
                            log::debug!("mpv: {}", text.trim());
                        }
                    }
                    mpv_event_id_MPV_EVENT_END_FILE => {
                        log::info!("mpv: End of file");
                        self.is_playing.store(false, Ordering::Relaxed);
                    }
                    mpv_event_id_MPV_EVENT_PLAYBACK_RESTART => {
                        log::info!("mpv: Playback restarted");
                    }
                    _ => {}
                }
            }
        }
    }
}

impl Drop for MediaPlayer {
    fn drop(&mut self) {
        unsafe {
            if !self.mpv.is_null() {
                mpv_terminate_destroy(self.mpv);
            }
        }
    }
}

// Stream callback implementations

/// Called when mpv opens the stream
unsafe extern "C" fn stream_open_callback(
    user_data: *mut c_void,
    uri: *mut c_char,
    info: *mut mpv_stream_cb_info,
) -> c_int {
    if user_data.is_null() || info.is_null() {
        eprintln!("[mpv] stream_open_callback: null pointer");
        return -1;
    }

    let uri_str = CStr::from_ptr(uri).to_string_lossy();
    eprintln!("[mpv] Opening stream: {}", uri_str);
    log::info!("Opening stream: {}", uri_str);

    // Set up the stream info
    (*info).cookie = user_data;
    (*info).read_fn = Some(stream_read_callback);
    (*info).close_fn = Some(stream_close_callback);
    (*info).seek_fn = None; // No seeking for live streams
    (*info).size_fn = None; // Unknown size for live streams

    eprintln!("[mpv] Stream callbacks registered");
    0 // Success
}

/// Called when mpv reads from the stream
unsafe extern "C" fn stream_read_callback(
    cookie: *mut c_void,
    buf: *mut c_char,
    size: u64,
) -> i64 {
    if cookie.is_null() || buf.is_null() || size == 0 {
        eprintln!("[mpv] stream_read_callback: invalid params");
        return -1;
    }

    let ctx = &*(cookie as *const StreamContext);
    let slice = std::slice::from_raw_parts_mut(buf as *mut u8, size as usize);

    let bytes_read = ctx.buffer.read(slice);

    if bytes_read > 0 {
        let pos = ctx.position.fetch_add(bytes_read as u64, Ordering::Relaxed);
        if pos == 0 || pos % 100000 < (bytes_read as u64) {
            eprintln!("[mpv] Read {} bytes, total position: {}", bytes_read, pos + bytes_read as u64);
        }
    } else if bytes_read == 0 {
        eprintln!("[mpv] Read returned 0 (EOF or waiting)");
    }

    bytes_read
}

/// Called when mpv closes the stream
unsafe extern "C" fn stream_close_callback(_cookie: *mut c_void) {
    log::info!("Stream closed");
    // Note: We don't free the cookie here as it's owned by MediaPlayer
}

// Global player registry
use dashmap::DashMap;
use once_cell::sync::Lazy;

static PLAYERS: Lazy<DashMap<u64, MediaPlayer>> = Lazy::new(|| DashMap::new());
static NEXT_PLAYER_ID: AtomicU64 = AtomicU64::new(1);

// FFI Functions

/// Create a new media player with window output (default)
/// Returns player ID or 0 on error
#[no_mangle]
pub extern "C" fn media_player_create() -> u64 {
    media_player_create_with_output(0) // 0 = Window
}

/// Create a new media player with specific video output mode
/// video_output: 0=Window, 1=Null (audio only), 2=Texture
/// Returns player ID or 0 on error
#[no_mangle]
pub extern "C" fn media_player_create_with_output(video_output: c_int) -> u64 {
    // Catch any panics to prevent crashing the Flutter app
    let result = std::panic::catch_unwind(|| {
        let vo = match video_output {
            0 => VideoOutput::Window,
            1 => VideoOutput::Null,
            2 => VideoOutput::Texture,
            _ => VideoOutput::Window,
        };

        eprintln!("[mpv] media_player_create_with_output called with vo={:?}", vo);

        match MediaPlayer::with_video_output(vo) {
            Ok(mut player) => {
                eprintln!("[mpv] MediaPlayer created, registering protocol...");
                if let Err(e) = player.register_protocol() {
                    eprintln!("[mpv] Failed to register protocol: {}", e);
                    log::error!("Failed to register protocol: {}", e);
                    return 0;
                }

                let id = NEXT_PLAYER_ID.fetch_add(1, Ordering::Relaxed);
                PLAYERS.insert(id, player);
                eprintln!("[mpv] Created media player {} with {:?} output", id, vo);
                log::info!("Created media player {} with {:?} output", id, vo);
                id
            }
            Err(e) => {
                eprintln!("[mpv] Failed to create media player: {}", e);
                log::error!("Failed to create media player: {}", e);
                0
            }
        }
    });

    match result {
        Ok(id) => id,
        Err(e) => {
            eprintln!("[mpv] PANIC in media_player_create_with_output: {:?}", e);
            0
        }
    }
}

/// Destroy a media player
#[no_mangle]
pub extern "C" fn media_player_destroy(player_id: u64) {
    if let Some((_, player)) = PLAYERS.remove(&player_id) {
        log::info!("Destroyed media player {}", player_id);
        drop(player);
    }
}

/// Write data to the player's buffer
/// Returns number of bytes written
#[no_mangle]
pub extern "C" fn media_player_write(
    player_id: u64,
    data: *const u8,
    len: usize,
) -> usize {
    if data.is_null() || len == 0 {
        return 0;
    }

    let slice = unsafe { std::slice::from_raw_parts(data, len) };

    if let Some(player) = PLAYERS.get(&player_id) {
        player.write_data(slice)
    } else {
        0
    }
}

/// Start playback
/// Returns 0 on success, -1 on error
#[no_mangle]
pub extern "C" fn media_player_play(player_id: u64) -> c_int {
    if let Some(player) = PLAYERS.get(&player_id) {
        match player.play() {
            Ok(()) => 0,
            Err(e) => {
                log::error!("Play failed: {}", e);
                -1
            }
        }
    } else {
        -1
    }
}

/// Pause playback
#[no_mangle]
pub extern "C" fn media_player_pause(player_id: u64) -> c_int {
    if let Some(player) = PLAYERS.get(&player_id) {
        match player.pause() {
            Ok(()) => 0,
            Err(_) => -1,
        }
    } else {
        -1
    }
}

/// Resume playback
#[no_mangle]
pub extern "C" fn media_player_resume(player_id: u64) -> c_int {
    if let Some(player) = PLAYERS.get(&player_id) {
        match player.resume() {
            Ok(()) => 0,
            Err(_) => -1,
        }
    } else {
        -1
    }
}

/// Stop playback
#[no_mangle]
pub extern "C" fn media_player_stop(player_id: u64) -> c_int {
    if let Some(player) = PLAYERS.get(&player_id) {
        match player.stop() {
            Ok(()) => 0,
            Err(_) => -1,
        }
    } else {
        -1
    }
}

/// Signal end of stream
#[no_mangle]
pub extern "C" fn media_player_end_stream(player_id: u64) {
    if let Some(player) = PLAYERS.get(&player_id) {
        player.end_stream();
    }
}

/// Process events (call periodically)
#[no_mangle]
pub extern "C" fn media_player_process_events(player_id: u64) {
    if let Some(player) = PLAYERS.get(&player_id) {
        player.process_events();
    }
}

/// Get buffer statistics
/// Fills out_buffered, out_written, out_read
#[no_mangle]
pub extern "C" fn media_player_get_stats(
    player_id: u64,
    out_buffered: *mut usize,
    out_written: *mut u64,
    out_read: *mut u64,
) -> c_int {
    if let Some(player) = PLAYERS.get(&player_id) {
        let (buffered, written, read) = player.buffer_stats();
        unsafe {
            if !out_buffered.is_null() {
                *out_buffered = buffered;
            }
            if !out_written.is_null() {
                *out_written = written;
            }
            if !out_read.is_null() {
                *out_read = read;
            }
        }
        0
    } else {
        -1
    }
}

/// Check if player is currently playing
#[no_mangle]
pub extern "C" fn media_player_is_playing(player_id: u64) -> c_int {
    if let Some(player) = PLAYERS.get(&player_id) {
        if player.is_playing() { 1 } else { 0 }
    } else {
        0
    }
}
