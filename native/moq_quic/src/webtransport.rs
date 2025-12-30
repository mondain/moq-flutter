// MoQ WebTransport support
// Uses web-transport-quinn crate for WebTransport over HTTP/3

use web_transport_quinn::{Session, Client as WebTransportClient, SendStream};
use quinn::{Endpoint, ClientConfig, TokioRuntime, EndpointConfig};
use quinn::crypto::rustls::QuicClientConfig;
use rustls::pki_types::{ServerName, CertificateDer, UnixTime};
use dashmap::DashMap;
use once_cell::sync::OnceCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::runtime::Runtime;
use std::slice;
use std::ffi::c_char;
use std::collections::VecDeque;
use std::sync::Mutex;
use log;
use std::fs::OpenOptions;
use std::io::Write;

/// Write debug message to log file
fn debug_log(msg: &str) {
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/moq_webtransport.log")
    {
        let _ = writeln!(file, "{}", msg);
    }
}

// Maximum receive buffer size per session
const MAX_RECV_BUFFER_SIZE: usize = 64 * 1024; // 64KB
// Maximum error message length
const MAX_ERROR_LEN: usize = 512;

// Last error message (for retrieval after error)
static LAST_ERROR: OnceCell<Mutex<Vec<u8>>> = OnceCell::new();

// Control stream storage - only send stream needed (recv is handled by background task)
struct ControlStream {
    send: SendStream,
}

// Data stream storage for unidirectional streams
static WT_DATA_STREAMS: OnceCell<DashMap<(u64, u64), Arc<tokio::sync::Mutex<SendStream>>>> = OnceCell::new();
static WT_NEXT_STREAM_ID: AtomicU64 = AtomicU64::new(1);

// Receive buffer for incoming data
struct ReceiveBuffer {
    data: VecDeque<u8>,
    max_size: usize,
}

impl ReceiveBuffer {
    fn new(max_size: usize) -> Self {
        Self {
            data: VecDeque::with_capacity(1024),
            max_size,
        }
    }

    fn push(&mut self, bytes: &[u8]) -> usize {
        let available = self.max_size - self.data.len();
        let to_copy = bytes.len().min(available);
        for &byte in &bytes[..to_copy] {
            self.data.push_back(byte);
        }
        to_copy
    }

    fn pop(&mut self, buf: &mut [u8]) -> usize {
        let to_read = buf.len().min(self.data.len());
        for i in 0..to_read {
            buf[i] = self.data.pop_front().unwrap();
        }
        to_read
    }

    #[allow(dead_code)]
    fn len(&self) -> usize {
        self.data.len()
    }

    fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

// Global registry for WebTransport sessions
static WT_SESSIONS: OnceCell<DashMap<u64, Arc<Session>>> = OnceCell::new();
static WT_ENDPOINTS: OnceCell<DashMap<u64, Arc<Endpoint>>> = OnceCell::new();
static WT_RECV_BUFFERS: OnceCell<DashMap<u64, Arc<tokio::sync::Mutex<ReceiveBuffer>>>> = OnceCell::new();
static WT_CONTROL_STREAMS: OnceCell<DashMap<u64, Arc<tokio::sync::Mutex<Option<ControlStream>>>>> = OnceCell::new();
static WT_RUNTIME: OnceCell<Runtime> = OnceCell::new();
static WT_NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

/// No certificate verification for testing
#[derive(Debug)]
struct NoVerification;

impl rustls::client::danger::ServerCertVerifier for NoVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
        ]
    }
}

/// Get the global Tokio runtime
fn get_runtime() -> &'static Runtime {
    WT_RUNTIME.get().expect("Runtime not initialized - call moq_webtransport_init first")
}

/// Initialize WebTransport module
///
/// # Arguments
/// * `runtime_ptr` - Pointer to the Tokio runtime (from main module)
#[no_mangle]
pub extern "C" fn moq_webtransport_init() {
    if WT_SESSIONS.set(DashMap::new()).is_err() {
        log::warn!("WebTransport sessions registry already initialized");
    }
    if WT_ENDPOINTS.set(DashMap::new()).is_err() {
        log::warn!("WebTransport endpoints registry already initialized");
    }
    if WT_RECV_BUFFERS.set(DashMap::new()).is_err() {
        log::warn!("WebTransport receive buffers registry already initialized");
    }
    if WT_CONTROL_STREAMS.set(DashMap::new()).is_err() {
        log::warn!("WebTransport control streams registry already initialized");
    }
    if WT_DATA_STREAMS.set(DashMap::new()).is_err() {
        log::warn!("WebTransport data streams registry already initialized");
    }
    if LAST_ERROR.set(Mutex::new(Vec::new())).is_err() {
        log::warn!("WebTransport last error buffer already initialized");
    }
    log::info!("MoQ WebTransport module initialized");
}

/// Set the last error message
fn set_last_error(msg: &str) {
    if let Some(error_buf) = LAST_ERROR.get() {
        let mut buf = error_buf.lock().unwrap();
        let msg_bytes = msg.as_bytes();
        let len = msg_bytes.len().min(MAX_ERROR_LEN);
        buf.clear();
        buf.extend_from_slice(&msg_bytes[..len]);
    }
}

/// Set the runtime for WebTransport (shared with main module)
#[no_mangle]
pub extern "C" fn moq_webtransport_set_runtime(runtime_ptr: *const Runtime) {
    if !runtime_ptr.is_null() {
        let _runtime = unsafe { &*runtime_ptr };
        // Note: We can't store a reference to a runtime that's owned elsewhere
        // This is a limitation - in production you'd want a different approach
        log::warn!("Runtime sharing not implemented - WebTransport will create its own runtime");
    }
}

/// Connect to a WebTransport server
///
/// # Arguments
/// * `host` - The hostname to connect to (must be null-terminated)
/// * `port` - The port to connect to
/// * `path` - The URL path for WebTransport (e.g., "/moq") (must be null-terminated)
/// * `insecure` - If non-zero, skip certificate verification
/// * `out_session_id` - Output parameter for the session ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_webtransport_connect(
    host: *const c_char,
    port: u16,
    path: *const c_char,
    _insecure: u8,
    out_session_id: *mut u64,
) -> i32 {
    let host_str = unsafe {
        if host.is_null() {
            return -1;
        }
        match std::ffi::CStr::from_ptr(host).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return -2,
        }
    };

    let path_str = unsafe {
        if path.is_null() {
            return -1;
        }
        match std::ffi::CStr::from_ptr(path).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return -2,
        }
    };

    // Create runtime if not exists
    if WT_RUNTIME.get().is_none() {
        WT_RUNTIME.set(Runtime::new().expect("Failed to create Tokio runtime"))
            .expect("Failed to set runtime");
    }

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        // Build URL for WebTransport
        let url = format!("https://{}:{}{}", host_str, port, path_str);
        log::info!("Connecting to WebTransport: {}", url);

        let parsed_url = match url.parse() {
            Ok(u) => u,
            Err(e) => {
                log::error!("Failed to parse URL: {:?}", e);
                return Err(-8);
            }
        };

        // Create client configuration
        // For now, we use NoVerification for both modes since:
        // 1. Development servers typically use self-signed certificates
        // 2. Loading system root certs requires additional dependencies
        // 3. The user can enable 'insecure' mode checkbox in the UI
        //
        // IMPORTANT: ALPN protocols for MoQ over WebTransport
        // Per draft-ietf-moq-transport-14, WebTransport uses h3 ALPN
        // But we also advertise moq protocol for compatibility
        let mut crypto = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(NoVerification))
            .with_no_client_auth();
        // Set ALPN protocols - include both h3 (for WebTransport) and moq (for MoQ)
        crypto.alpn_protocols = vec![
            b"moq-00".to_vec(),      // MoQ protocol (draft-00)
            b"h3".to_vec(),           // HTTP/3 (for WebTransport)
            b"h3-29".to_vec(),        // HTTP/3 draft-29
            b"h3-28".to_vec(),        // HTTP/3 draft-28
        ];

        let quic_crypto = match QuicClientConfig::try_from(crypto.clone()) {
            Ok(c) => c,
            Err(e) => {
                let err_msg = format!("QuicClientConfig error: {}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-6);
            }
        };

        let client_config = ClientConfig::new(Arc::new(quic_crypto));

        // Create endpoint
        let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                let err_msg = format!("UDP bind error: {}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-5);
            }
        };

        let mut endpoint = match Endpoint::new(
            EndpointConfig::default(),
            None,
            socket,
            Arc::new(TokioRuntime),
        ) {
            Ok(e) => e,
            Err(e) => {
                let err_msg = format!("Endpoint creation error: {}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-6);
            }
        };

        endpoint.set_default_client_config(client_config.clone());

        // Connect using WebTransport
        let client = WebTransportClient::new(endpoint.clone(), client_config);

        match client.connect(parsed_url).await {
            Ok(session) => {
                log::info!("WebTransport session established");
                Ok((session, endpoint))
            }
            Err(e) => {
                let err_msg = format!("WebTransport connection failed: {} (URL: {})", e, url);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                Err(-7)
            }
        }
    });

    let (session, endpoint) = match result {
        Ok((s, e)) => (s, e),
        Err(e) => return e,
    };

    // Allocate session ID
    let session_id = WT_NEXT_SESSION_ID.fetch_add(1, Ordering::SeqCst);

    // Store session and endpoint
    let sessions = WT_SESSIONS.get().expect("Sessions not initialized");
    let endpoints = WT_ENDPOINTS.get().expect("Endpoints not initialized");
    let recv_buffers = WT_RECV_BUFFERS.get().expect("Receive buffers not initialized");
    let control_streams = WT_CONTROL_STREAMS.get().expect("Control streams not initialized");

    let session_arc = Arc::new(session);
    let endpoint_arc = Arc::new(endpoint);
    let recv_buffer = Arc::new(tokio::sync::Mutex::new(ReceiveBuffer::new(MAX_RECV_BUFFER_SIZE)));

    sessions.insert(session_id, session_arc.clone());
    endpoints.insert(session_id, endpoint_arc);
    recv_buffers.insert(session_id, recv_buffer.clone());
    control_streams.insert(session_id, Arc::new(tokio::sync::Mutex::new(None)));

    // Open bidirectional control stream (required by MoQ spec)
    let control_stream_for_opening = session_arc.clone();
    let recv_buffer_for_control = recv_buffer.clone();
    let runtime = get_runtime();
    runtime.spawn(async move {
        log::info!("Opening bidirectional control stream for session {}", session_id);
        match control_stream_for_opening.open_bi().await {
            Ok((send, mut recv)) => {
                log::info!("Bidirectional control stream opened for session {}", session_id);
                let control_streams = WT_CONTROL_STREAMS.get().expect("Control streams not initialized");

                // Store the send stream for sending control messages
                if let Some(ctrl_stream_mutex) = control_streams.get(&session_id) {
                    *ctrl_stream_mutex.lock().await = Some(ControlStream { send });
                }

                // Start reading from the control stream's receive side
                let mut buffer = vec![0u8; 4096];
                loop {
                    match recv.read(&mut buffer).await {
                        Ok(None) => {
                            log::debug!("Control stream closed for session {}", session_id);
                            break;
                        }
                        Ok(Some(n)) => {
                            // Add data to receive buffer (control messages don't have stream type prefix)
                            let mut recv_buf = recv_buffer_for_control.lock().await;
                            let pushed = recv_buf.push(&buffer[..n]);
                            if pushed < n {
                                log::warn!("Receive buffer full, dropped {} bytes", n - pushed);
                            }
                            log::trace!("Received {} bytes on control stream for session {}", n, session_id);
                        }
                        Err(e) => {
                            log::error!("Error reading from control stream: {:?}", e);
                            break;
                        }
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to open control stream for session {}: {:?}", session_id, e);
            }
        }
    });

    // Start background task to accept incoming unidirectional streams (data streams)
    let session_for_task = session_arc.clone();
    let recv_buffer_for_task = recv_buffer.clone();
    runtime.spawn(async move {
        log::info!("Starting WebTransport data stream acceptor for session {}", session_id);
        loop {
            match session_for_task.accept_uni().await {
                Ok(mut recv_stream) => {
                    log::debug!("Accepted incoming unidirectional stream on session {}", session_id);
                    // Read all data from this stream
                    let mut buffer = vec![0u8; 4096];
                    loop {
                        match recv_stream.read(&mut buffer).await {
                            Ok(None) => {
                                // Stream closed
                                log::debug!("Incoming stream closed on session {}", session_id);
                                break;
                            }
                            Ok(Some(n)) => {
                                // Add data to receive buffer
                                let mut recv_buf = recv_buffer_for_task.lock().await;
                                let pushed = recv_buf.push(&buffer[..n]);
                                if pushed < n {
                                    log::warn!("Receive buffer full, dropped {} bytes", n - pushed);
                                }
                                log::trace!("Received {} bytes on WebTransport session {}", n, session_id);
                            }
                            Err(e) => {
                                log::error!("Error reading from stream: {:?}", e);
                                break;
                            }
                        }
                    }
                }
                Err(e) => {
                    log::error!("Error accepting incoming stream: {:?}", e);
                    // Session might be closed
                    break;
                }
            }
        }
        log::info!("WebTransport stream acceptor stopped for session {}", session_id);
    });

    unsafe {
        *out_session_id = session_id;
    }

    log::info!("WebTransport session created (ID: {})", session_id);
    0
}

/// Send data over a WebTransport control stream
///
/// Per MoQ spec, the first stream is a client-initiated bidirectional control stream.
/// All control messages are sent on this stream.
///
/// # Arguments
/// * `session_id` - The session ID
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Number of bytes sent on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_webtransport_send(
    session_id: u64,
    data: *const u8,
    len: usize,
) -> i64 {
    let control_streams = WT_CONTROL_STREAMS.get().expect("Control streams not initialized");

    let control_stream_mutex = match control_streams.get(&session_id) {
        Some(cs) => cs.clone(),
        None => {
            log::error!("Control stream {} not found", session_id);
            return -1;
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };
    let data_to_send = data_bytes.to_vec();

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut control_stream_guard = control_stream_mutex.lock().await;

        // Wait for control stream to be available (it's opened asynchronously)
        // If it's not available yet, wait a bit
        let max_retries = 50; // 5 seconds max (50 * 100ms)
        let mut retries = 0;

        while control_stream_guard.is_none() && retries < max_retries {
            drop(control_stream_guard);
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            control_stream_guard = control_stream_mutex.lock().await;
            retries += 1;
        }

        let control_stream: &mut ControlStream = match control_stream_guard.as_mut() {
            Some(cs) => cs,
            None => {
                log::error!("Control stream not available for session {}", session_id);
                return -2;
            }
        };

        // Send on the bidirectional control stream
        match control_stream.send.write_all(&data_to_send).await {
            Ok(_) => {
                // For bidirectional control stream, we don't close it after each send
                len as i64
            }
            Err(e) => {
                log::error!("Failed to write to control stream: {:?}", e);
                -2
            }
        }
    });

    result
}

/// Check if session is active
#[no_mangle]
pub extern "C" fn moq_webtransport_is_connected(session_id: u64) -> i32 {
    let sessions = WT_SESSIONS.get().expect("Sessions not initialized");
    if sessions.contains_key(&session_id) {
        1
    } else {
        0
    }
}

/// Receive data from WebTransport session (non-blocking poll)
///
/// # Arguments
/// * `session_id` - The session ID
/// * `buffer` - Pointer to buffer to store received data
/// * `buffer_len` - Length of buffer
///
/// # Returns
/// * Number of bytes received on success, 0 if no data available, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_webtransport_recv(
    session_id: u64,
    buffer: *mut u8,
    buffer_len: usize,
) -> i64 {
    let recv_buffers = WT_RECV_BUFFERS.get().expect("Receive buffers not initialized");

    let recv_buffer = match recv_buffers.get(&session_id) {
        Some(rb) => rb.clone(),
        None => {
            log::error!("Session {} not found for recv", session_id);
            return -1;
        }
    };

    if buffer.is_null() || buffer_len == 0 {
        return 0;
    }

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut recv_buf = recv_buffer.lock().await;

        if recv_buf.is_empty() {
            0
        } else {
            let output_buf = unsafe { slice::from_raw_parts_mut(buffer, buffer_len) };
            let bytes_read = recv_buf.pop(output_buf);
            bytes_read as i64
        }
    });

    result
}

/// Open a unidirectional stream for sending data
///
/// # Arguments
/// * `session_id` - The session ID
/// * `out_stream_id` - Output parameter for the stream ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_webtransport_open_uni_stream(
    session_id: u64,
    out_stream_id: *mut u64,
) -> i32 {
    debug_log(&format!("[WT-DEBUG] open_uni_stream called for session {}", session_id));

    let sessions = WT_SESSIONS.get().expect("Sessions not initialized");
    let data_streams = WT_DATA_STREAMS.get().expect("Data streams not initialized");

    debug_log(&format!("[WT-DEBUG] Looking up session {}", session_id));
    let session = match sessions.get(&session_id) {
        Some(s) => s.clone(),
        None => {
            debug_log(&format!("[WT-ERROR] Session {} not found for open_uni_stream", session_id));
            return -1;
        }
    };
    debug_log(&format!("[WT-DEBUG] Session {} found", session_id));

    let runtime = get_runtime();
    debug_log("[WT-DEBUG] Got runtime, calling block_on for open_uni");

    let result = runtime.block_on(async {
        debug_log("[WT-DEBUG] Inside async block, calling session.open_uni()");
        match session.open_uni().await {
            Ok(send_stream) => {
                let stream_id = WT_NEXT_STREAM_ID.fetch_add(1, Ordering::SeqCst);
                data_streams.insert((session_id, stream_id), Arc::new(tokio::sync::Mutex::new(send_stream)));
                log::debug!("Opened unidirectional stream {} for session {}", stream_id, session_id);
                Ok(stream_id)
            }
            Err(e) => {
                let err_msg = format!("Failed to open uni stream: {}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                Err(-2)
            }
        }
    });

    match result {
        Ok(stream_id) => {
            if !out_stream_id.is_null() {
                unsafe { *out_stream_id = stream_id; }
            }
            0
        }
        Err(e) => e,
    }
}

/// Write data to a unidirectional stream
///
/// # Arguments
/// * `session_id` - The session ID
/// * `stream_id` - The stream ID (from open_uni_stream)
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Number of bytes written on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_webtransport_stream_write(
    session_id: u64,
    stream_id: u64,
    data: *const u8,
    len: usize,
) -> i64 {
    let data_streams = WT_DATA_STREAMS.get().expect("Data streams not initialized");

    let stream_mutex = match data_streams.get(&(session_id, stream_id)) {
        Some(s) => s.clone(),
        None => {
            log::error!("Stream {} not found for session {}", stream_id, session_id);
            return -1;
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };
    let data_to_send = data_bytes.to_vec();

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut stream = stream_mutex.lock().await;
        match stream.write_all(&data_to_send).await {
            Ok(_) => {
                log::trace!("Wrote {} bytes to stream {} on session {}", len, stream_id, session_id);
                len as i64
            }
            Err(e) => {
                log::error!("Failed to write to stream {}: {:?}", stream_id, e);
                -2
            }
        }
    });

    result
}

/// Finish (close) a unidirectional stream
///
/// # Arguments
/// * `session_id` - The session ID
/// * `stream_id` - The stream ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_webtransport_stream_finish(
    session_id: u64,
    stream_id: u64,
) -> i32 {
    let data_streams = WT_DATA_STREAMS.get().expect("Data streams not initialized");

    let stream_mutex = match data_streams.remove(&(session_id, stream_id)) {
        Some((_, s)) => s,
        None => {
            log::warn!("Stream {} not found for session {} during finish", stream_id, session_id);
            return -1;
        }
    };

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut stream = stream_mutex.lock().await;
        match stream.finish() {
            Ok(_) => {
                log::debug!("Finished stream {} on session {}", stream_id, session_id);
                0
            }
            Err(e) => {
                log::error!("Failed to finish stream {}: {:?}", stream_id, e);
                -2
            }
        }
    });

    result
}

/// Close a WebTransport session
#[no_mangle]
pub extern "C" fn moq_webtransport_close(session_id: u64) -> i32 {
    let sessions = WT_SESSIONS.get().expect("Sessions not initialized");
    let endpoints = WT_ENDPOINTS.get().expect("Endpoints not initialized");
    let recv_buffers = WT_RECV_BUFFERS.get().expect("Receive buffers not initialized");
    let control_streams = WT_CONTROL_STREAMS.get().expect("Control streams not initialized");
    let data_streams = WT_DATA_STREAMS.get().expect("Data streams not initialized");

    let (_, _) = match sessions.remove(&session_id) {
        Some(s) => s,
        None => {
            log::warn!("Session {} not found for close", session_id);
            return -1;
        }
    };

    let (_, _) = match endpoints.remove(&session_id) {
        Some(e) => e,
        None => {
            log::warn!("Endpoint {} not found for close", session_id);
            return -1;
        }
    };

    recv_buffers.remove(&session_id);
    control_streams.remove(&session_id);

    // Clean up any data streams for this session
    data_streams.retain(|(sid, _), _| *sid != session_id);

    log::info!("WebTransport session {} closed", session_id);
    0
}

/// Cleanup the WebTransport module
#[no_mangle]
pub extern "C" fn moq_webtransport_cleanup() {
    let sessions = WT_SESSIONS.get().expect("Sessions not initialized");
    let endpoints = WT_ENDPOINTS.get().expect("Endpoints not initialized");
    let recv_buffers = WT_RECV_BUFFERS.get().expect("Receive buffers not initialized");
    let control_streams = WT_CONTROL_STREAMS.get().expect("Control streams not initialized");
    let data_streams = WT_DATA_STREAMS.get().expect("Data streams not initialized");

    sessions.clear();
    endpoints.clear();
    recv_buffers.clear();
    control_streams.clear();
    data_streams.clear();

    log::info!("MoQ WebTransport cleanup complete");
}

/// Get the last error message
///
/// # Arguments
/// * `buffer` - Pointer to buffer to store error message
/// * `buffer_len` - Length of buffer
///
/// # Returns
/// * Number of bytes written to buffer on success, 0 if no error
#[no_mangle]
pub extern "C" fn moq_webtransport_get_last_error(
    buffer: *mut u8,
    buffer_len: usize,
) -> i32 {
    if buffer.is_null() || buffer_len == 0 {
        return 0;
    }

    if let Some(error_buf) = LAST_ERROR.get() {
        let buf = error_buf.lock().unwrap();
        let to_copy = buf.len().min(buffer_len);
        if to_copy > 0 {
            unsafe {
                let dst = slice::from_raw_parts_mut(buffer, to_copy);
                dst.copy_from_slice(&buf[..to_copy]);
            }
            to_copy as i32
        } else {
            0
        }
    } else {
        0
    }
}
