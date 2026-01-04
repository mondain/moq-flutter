// MoQ QUIC Transport using Quinn
// FFI bindings for Flutter/Dart
//
// Architecture:
// - DashMap for thread-safe connection/stream registry
// - Bidirectional control stream for MoQ control messages
// - Receive buffer for polling from Dart
// - Background tasks for stream handling

mod stream_writer;
pub mod webtransport;

use quinn::{Endpoint, ClientConfig, Connection, SendStream, VarInt, TokioRuntime, EndpointConfig, TransportConfig};
use quinn::crypto::rustls::QuicClientConfig;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::crypto::CryptoProvider;
use dashmap::DashMap;
use once_cell::sync::OnceCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time;
use std::collections::VecDeque;
use std::sync::Mutex;
use tokio::runtime::Runtime;
use std::slice;
use std::ffi::c_char;

// Maximum receive buffer size per connection
const MAX_RECV_BUFFER_SIZE: usize = 64 * 1024; // 64KB

// No certificate verification for testing (DANGER: only use for development!)
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
            rustls::SignatureScheme::RSA_PKCS1_SHA1,
            rustls::SignatureScheme::ECDSA_SHA1_Legacy,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
        ]
    }
}

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

    fn is_empty(&self) -> bool {
        self.data.is_empty()
    }
}

// Control stream storage - only send stream needed (recv is handled by background task)
struct ControlStream {
    send: SendStream,
}

// Global Tokio runtime for async operations
static RUNTIME: OnceCell<Runtime> = OnceCell::new();

// Global registry of Quinn connections (connection_id -> connection)
static CONNECTIONS: OnceCell<DashMap<u64, Arc<Connection>>> = OnceCell::new();

// Global registry of endpoints (connection_id -> endpoint)
static ENDPOINTS: OnceCell<DashMap<u64, Arc<Endpoint>>> = OnceCell::new();

// Global registry of control streams (connection_id -> control stream)
static CONTROL_STREAMS: OnceCell<DashMap<u64, Arc<tokio::sync::Mutex<Option<ControlStream>>>>> = OnceCell::new();

// Global registry of receive buffers (connection_id -> receive buffer)
static RECV_BUFFERS: OnceCell<DashMap<u64, Arc<tokio::sync::Mutex<ReceiveBuffer>>>> = OnceCell::new();

// Global registry of stream writers (connection_id -> stream_id -> writer)
static STREAM_WRITERS: OnceCell<DashMap<(u64, u64), Arc<stream_writer::StreamWriter>>> = OnceCell::new();

// Global registry of incoming data stream buffers (connection_id, stream_id) -> buffer
// Used for receiving data from unidirectional streams (SUBGROUP_HEADER + objects)
static DATA_STREAM_BUFFERS: OnceCell<DashMap<(u64, u64), Arc<tokio::sync::Mutex<ReceiveBuffer>>>> = OnceCell::new();

// Global registry of active data streams per connection (connection_id -> list of stream_ids)
static ACTIVE_DATA_STREAMS: OnceCell<DashMap<u64, Arc<tokio::sync::Mutex<Vec<u64>>>>> = OnceCell::new();

// Global registry of datagram receive buffers (connection_id -> buffer of complete datagrams)
static DATAGRAM_BUFFERS: OnceCell<DashMap<u64, Arc<tokio::sync::Mutex<VecDeque<Vec<u8>>>>>> = OnceCell::new();

// Next connection ID counter
static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

// Last error message
static LAST_ERROR: OnceCell<Mutex<Vec<u8>>> = OnceCell::new();
const MAX_ERROR_LEN: usize = 512;

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

/// Get the global Tokio runtime
fn get_runtime() -> &'static Runtime {
    RUNTIME.get().expect("Runtime not initialized - call moq_quic_init first")
}

/// Initialize the QUIC transport module
///
/// IMPORTANT: Call this once before any other functions
#[no_mangle]
pub extern "C" fn moq_quic_init() {
    // Install default CryptoProvider for rustls (required for rustls 0.23+)
    #[cfg(feature = "aws-lc-rs")]
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    #[cfg(not(feature = "aws-lc-rs"))]
    let provider = rustls::crypto::ring::default_provider();
    let _ = CryptoProvider::install_default(provider);

    // Initialize Tokio runtime
    if RUNTIME.set(Runtime::new().expect("Failed to create Tokio runtime")).is_err() {
        log::warn!("Runtime already initialized");
    }

    // Initialize connection registry
    if CONNECTIONS.set(DashMap::new()).is_err() {
        log::warn!("Connection registry already initialized");
    }

    // Initialize endpoint registry
    if ENDPOINTS.set(DashMap::new()).is_err() {
        log::warn!("Endpoint registry already initialized");
    }

    // Initialize control streams registry
    if CONTROL_STREAMS.set(DashMap::new()).is_err() {
        log::warn!("Control streams registry already initialized");
    }

    // Initialize receive buffers registry
    if RECV_BUFFERS.set(DashMap::new()).is_err() {
        log::warn!("Receive buffers registry already initialized");
    }

    // Initialize stream writers registry
    if STREAM_WRITERS.set(DashMap::new()).is_err() {
        log::warn!("Stream writers registry already initialized");
    }

    // Initialize data stream buffers registry
    if DATA_STREAM_BUFFERS.set(DashMap::new()).is_err() {
        log::warn!("Data stream buffers registry already initialized");
    }

    // Initialize active data streams registry
    if ACTIVE_DATA_STREAMS.set(DashMap::new()).is_err() {
        log::warn!("Active data streams registry already initialized");
    }

    // Initialize datagram buffers registry
    if DATAGRAM_BUFFERS.set(DashMap::new()).is_err() {
        log::warn!("Datagram buffers registry already initialized");
    }

    // Initialize last error buffer
    if LAST_ERROR.set(Mutex::new(Vec::new())).is_err() {
        log::warn!("Last error buffer already initialized");
    }

    log::info!("MoQ QUIC transport initialized");
}

/// Create a new QUIC connection with bidirectional control stream
///
/// # Arguments
/// * `host` - The hostname to connect to (must be null-terminated)
/// * `port` - The port to connect to
/// * `insecure` - If non-zero, skip certificate verification (for testing only)
/// * `out_connection_id` - Output parameter for the connection ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_connect(
    host: *const c_char,
    port: u16,
    insecure: u8,
    out_connection_id: *mut u64,
) -> i32 {
    let host_str = unsafe {
        if host.is_null() {
            return -1; // Invalid host
        }
        match std::ffi::CStr::from_ptr(host).to_str() {
            Ok(s) => s.to_string(),
            Err(_) => return -2, // Invalid UTF-8
        }
    };

    let runtime = get_runtime();

    // Perform all connection setup within the runtime
    let result = runtime.block_on(async {
        // Resolve hostname to IP address (supports DNS)
        let addr_str = format!("{}:{}", host_str, port);
        let addrs = match tokio::net::lookup_host(&addr_str).await {
            Ok(addrs) => addrs,
            Err(e) => {
                let err_msg = format!("DNS resolution error for {}: {:?}", addr_str, e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-4);
            }
        };

        // Use the first resolved address
        let addr = match addrs.into_iter().next() {
            Some(a) => a,
            None => {
                set_last_error("No addresses resolved");
                return Err(-4);
            }
        };

        // Create client configuration with proper transport settings
        let certs = rustls::RootCertStore::empty();

        // Build transport config with standard settings (from moq-native-ietf)
        let mut transport = TransportConfig::default();
        transport.max_idle_timeout(Some(time::Duration::from_secs(30).try_into().unwrap()));
        transport.keep_alive_interval(Some(time::Duration::from_secs(4)));
        transport.max_concurrent_bidi_streams(100u32.into());
        transport.max_concurrent_uni_streams(100u32.into());
        // Enable datagrams with max size (for low-latency audio)
        transport.datagram_receive_buffer_size(Some(65536));
        transport.datagram_send_buffer_size(65536);

        // Create client configuration with ALPN protocols
        let client_crypto = if insecure != 0 {
            // Disable certificate verification for testing
            let builder = rustls::ClientConfig::builder()
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(NoVerification));
            builder.with_no_client_auth()
        } else {
            rustls::ClientConfig::builder()
                .with_root_certificates(certs)
                .with_no_client_auth()
        };

        // Set ALPN protocols - draft-14 specifies "moq-00"
        let mut client_crypto = client_crypto;
        client_crypto.alpn_protocols = vec![b"moq-00".to_vec()];

        let crypto = match QuicClientConfig::try_from(client_crypto) {
            Ok(c) => c,
            Err(e) => {
                let err_msg = format!("QuicClientConfig error: {:?}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-6);
            }
        };
        let mut client_config = ClientConfig::new(Arc::new(crypto));
        client_config.transport_config(Arc::new(transport));

        // Create endpoint with a UDP socket (std::net::UdpSocket, not tokio)
        let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                let err_msg = format!("UDP bind error: {:?}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-5);
            }
        };

        let mut endpoint = match Endpoint::new(
            EndpointConfig::default(),
            None, // No server config for client-only
            socket,
            Arc::new(TokioRuntime),
        ) {
            Ok(e) => e,
            Err(e) => {
                let err_msg = format!("Endpoint creation error: {:?}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-6);
            }
        };

        // Set the default client config
        endpoint.set_default_client_config(client_config);

        // Connect
        let connecting = match endpoint.connect(addr, &host_str) {
            Ok(c) => c,
            Err(e) => {
                let err_msg = format!("Connect error: {:?}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-6);
            }
        };

        let connection = match connecting.await {
            Ok(conn) => conn,
            Err(e) => {
                let err_msg = format!("Connection await error: {:?}", e);
                log::error!("{}", err_msg);
                set_last_error(&err_msg);
                return Err(-7);
            }
        };

        Ok((endpoint, connection))
    });

    let (endpoint, connection) = match result {
        Ok((e, c)) => (e, c),
        Err(e) => return e,
    };

    // Allocate connection ID
    let connection_id = NEXT_CONNECTION_ID.fetch_add(1, Ordering::SeqCst);

    // Store connection and endpoint IMMEDIATELY (before any other operations)
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");
    let endpoints = ENDPOINTS.get().expect("Endpoint registry not initialized");
    let control_streams = CONTROL_STREAMS.get().expect("Control streams not initialized");
    let recv_buffers = RECV_BUFFERS.get().expect("Receive buffers not initialized");
    let active_data_streams = ACTIVE_DATA_STREAMS.get().expect("Active data streams not initialized");

    let connection_arc = Arc::new(connection);
    let endpoint_arc = Arc::new(endpoint);
    let recv_buffer = Arc::new(tokio::sync::Mutex::new(ReceiveBuffer::new(MAX_RECV_BUFFER_SIZE)));

    connections.insert(connection_id, connection_arc.clone());
    endpoints.insert(connection_id, endpoint_arc);
    control_streams.insert(connection_id, Arc::new(tokio::sync::Mutex::new(None)));
    recv_buffers.insert(connection_id, recv_buffer.clone());
    active_data_streams.insert(connection_id, Arc::new(tokio::sync::Mutex::new(Vec::new())));

    // Initialize datagram buffer for this connection
    let datagram_buffers = DATAGRAM_BUFFERS.get().expect("Datagram buffers not initialized");
    datagram_buffers.insert(connection_id, Arc::new(tokio::sync::Mutex::new(VecDeque::new())));

    // Open bidirectional control stream (required by MoQ spec)
    let connection_for_control = connection_arc.clone();
    let recv_buffer_for_control = recv_buffer.clone();
    runtime.spawn(async move {
        log::info!("Opening bidirectional control stream for connection {}", connection_id);
        match connection_for_control.open_bi().await {
            Ok((send, mut recv)) => {
                log::info!("Bidirectional control stream opened for connection {}", connection_id);
                let control_streams = CONTROL_STREAMS.get().expect("Control streams not initialized");

                // Store the send stream for sending control messages
                if let Some(ctrl_stream_mutex) = control_streams.get(&connection_id) {
                    *ctrl_stream_mutex.lock().await = Some(ControlStream { send });
                }

                // Start reading from the control stream's receive side
                let mut buffer = vec![0u8; 4096];
                loop {
                    match recv.read(&mut buffer).await {
                        Ok(None) => {
                            log::debug!("Control stream closed for connection {}", connection_id);
                            break;
                        }
                        Ok(Some(n)) => {
                            // Add data to receive buffer
                            let mut recv_buf = recv_buffer_for_control.lock().await;
                            let pushed = recv_buf.push(&buffer[..n]);
                            if pushed < n {
                                log::warn!("Receive buffer full, dropped {} bytes", n - pushed);
                            }
                            log::trace!("Received {} bytes on control stream for connection {}", n, connection_id);
                        }
                        Err(e) => {
                            log::error!("Error reading from control stream: {:?}", e);
                            break;
                        }
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to open control stream for connection {}: {:?}", connection_id, e);
            }
        }
    });

    // Start accepting incoming unidirectional streams (data streams)
    let connection_for_streams = connection_arc.clone();
    runtime.spawn(async move {
        log::info!("Starting data stream acceptor for connection {}", connection_id);
        let data_stream_buffers = DATA_STREAM_BUFFERS.get().expect("Data stream buffers not initialized");
        let active_streams = ACTIVE_DATA_STREAMS.get().expect("Active data streams not initialized");

        loop {
            match connection_for_streams.accept_uni().await {
                Ok(mut recv_stream) => {
                    let stream_id = recv_stream.id().index();
                    log::debug!("Accepted incoming unidirectional stream {} on connection {}", stream_id, connection_id);

                    // Create a buffer for this specific data stream
                    let stream_buffer = Arc::new(tokio::sync::Mutex::new(ReceiveBuffer::new(MAX_RECV_BUFFER_SIZE)));
                    data_stream_buffers.insert((connection_id, stream_id), stream_buffer.clone());

                    // Add to active streams list
                    if let Some(streams_list) = active_streams.get(&connection_id) {
                        let mut list = streams_list.lock().await;
                        list.push(stream_id);
                    }

                    // Spawn task to read from this stream
                    tokio::spawn(async move {
                        let mut buffer = vec![0u8; 4096];
                        loop {
                            match recv_stream.read(&mut buffer).await {
                                Ok(None) => {
                                    log::debug!("Data stream {} closed on connection {}", stream_id, connection_id);
                                    // Note: We don't remove the buffer here - let Dart poll it dry first
                                    // Dart will call moq_quic_close_data_stream when done
                                    break;
                                }
                                Ok(Some(n)) => {
                                    // Add data to this stream's buffer (not the control stream buffer)
                                    let mut recv_buf = stream_buffer.lock().await;
                                    let pushed = recv_buf.push(&buffer[..n]);
                                    if pushed < n {
                                        log::warn!("Data stream {} buffer full, dropped {} bytes", stream_id, n - pushed);
                                    }
                                    log::trace!("Received {} bytes on data stream {} for connection {}", n, stream_id, connection_id);
                                }
                                Err(e) => {
                                    log::error!("Error reading from data stream {}: {:?}", stream_id, e);
                                    break;
                                }
                            }
                        }
                    });
                }
                Err(e) => {
                    log::error!("Error accepting incoming stream: {:?}", e);
                    // Connection might be closed
                    break;
                }
            }
        }
        log::info!("Data stream acceptor stopped for connection {}", connection_id);
    });

    // Start datagram receiver task
    let connection_for_datagrams = connection_arc.clone();
    runtime.spawn(async move {
        log::info!("Starting datagram receiver for connection {}", connection_id);
        let datagram_buffers = DATAGRAM_BUFFERS.get().expect("Datagram buffers not initialized");

        loop {
            match connection_for_datagrams.read_datagram().await {
                Ok(datagram) => {
                    log::trace!("Received datagram ({} bytes) on connection {}", datagram.len(), connection_id);

                    // Store the complete datagram in the buffer
                    if let Some(buffer) = datagram_buffers.get(&connection_id) {
                        let mut buf = buffer.lock().await;
                        // Limit buffer size to prevent unbounded growth
                        const MAX_DATAGRAM_BUFFER: usize = 1000;
                        if buf.len() < MAX_DATAGRAM_BUFFER {
                            buf.push_back(datagram.to_vec());
                        } else {
                            log::warn!("Datagram buffer full, dropping datagram");
                        }
                    }
                }
                Err(e) => {
                    log::error!("Error receiving datagram: {:?}", e);
                    // Connection might be closed
                    break;
                }
            }
        }
        log::info!("Datagram receiver stopped for connection {}", connection_id);
    });

    unsafe {
        *out_connection_id = connection_id;
    }

    log::info!("QUIC connection established (ID: {})", connection_id);
    0
}

/// Send data over the bidirectional control stream
///
/// Per MoQ spec, the first stream is a client-initiated bidirectional control stream.
/// All control messages are sent on this stream.
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Number of bytes sent on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_send(
    connection_id: u64,
    data: *const u8,
    len: usize,
) -> i64 {
    let control_streams = CONTROL_STREAMS.get().expect("Control streams not initialized");

    let control_stream_mutex = match control_streams.get(&connection_id) {
        Some(cs) => cs.clone(),
        None => {
            log::error!("Control stream {} not found", connection_id);
            return -1;
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };
    let data_to_send = data_bytes.to_vec();

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut control_stream_guard = control_stream_mutex.lock().await;

        // Wait for control stream to be available (it's opened asynchronously)
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
                log::error!("Control stream not available for connection {}", connection_id);
                return -2;
            }
        };

        // Send on the bidirectional control stream
        match control_stream.send.write_all(&data_to_send).await {
            Ok(_) => {
                log::debug!("Sent {} bytes on control stream for connection {}", len, connection_id);
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

/// Receive data from the QUIC connection (non-blocking poll)
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `buffer` - Pointer to buffer to store received data
/// * `buffer_len` - Length of buffer
///
/// # Returns
/// * Number of bytes received on success, 0 if no data available, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_recv(
    connection_id: u64,
    buffer: *mut u8,
    buffer_len: usize,
) -> i64 {
    let recv_buffers = RECV_BUFFERS.get().expect("Receive buffers not initialized");

    let recv_buffer = match recv_buffers.get(&connection_id) {
        Some(rb) => rb.clone(),
        None => {
            log::error!("Connection {} not found for recv", connection_id);
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

/// Check if connection is established
#[no_mangle]
pub extern "C" fn moq_quic_is_connected(connection_id: u64) -> i32 {
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");
    if connections.contains_key(&connection_id) {
        1
    } else {
        0
    }
}

/// Close a QUIC connection
#[no_mangle]
pub extern "C" fn moq_quic_close(connection_id: u64) -> i32 {
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");
    let endpoints = ENDPOINTS.get().expect("Endpoint registry not initialized");
    let control_streams = CONTROL_STREAMS.get().expect("Control streams not initialized");
    let recv_buffers = RECV_BUFFERS.get().expect("Receive buffers not initialized");
    let data_stream_buffers = DATA_STREAM_BUFFERS.get().expect("Data stream buffers not initialized");
    let active_data_streams = ACTIVE_DATA_STREAMS.get().expect("Active data streams not initialized");

    let (_, connection) = match connections.remove(&connection_id) {
        Some(conn) => conn,
        None => {
            log::warn!("Connection {} not found for close", connection_id);
            return -1;
        }
    };

    let (_, endpoint) = match endpoints.remove(&connection_id) {
        Some(endpoint) => endpoint,
        None => {
            log::warn!("Endpoint {} not found for close", connection_id);
            return -1;
        }
    };

    // Clean up control stream and receive buffer
    control_streams.remove(&connection_id);
    recv_buffers.remove(&connection_id);

    // Clean up stream writers for this connection
    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");
    stream_writers.retain(|key, _| key.0 != connection_id);

    // Clean up data stream buffers for this connection
    data_stream_buffers.retain(|key, _| key.0 != connection_id);

    // Clean up active data streams list
    active_data_streams.remove(&connection_id);

    // Clean up datagram buffer
    let datagram_buffers = DATAGRAM_BUFFERS.get().expect("Datagram buffers not initialized");
    datagram_buffers.remove(&connection_id);

    let runtime = get_runtime();

    // Close connection within runtime context
    let _ = runtime.block_on(async {
        connection.close(VarInt::from_u32(0), b"");
        endpoint.wait_idle().await;
    });

    log::info!("Connection {} closed", connection_id);
    0
}

/// Cleanup the QUIC transport module
#[no_mangle]
pub extern "C" fn moq_quic_cleanup() {
    let runtime = get_runtime();

    // Collect all connections and endpoints to close
    let connections_to_close: Vec<_> = {
        let connections = CONNECTIONS.get().expect("Connection registry not initialized");
        connections.iter().map(|entry| (*entry.key(), entry.value().clone())).collect()
    };

    let endpoints_to_idle: Vec<_> = {
        let endpoints = ENDPOINTS.get().expect("Endpoint registry not initialized");
        endpoints.iter().map(|entry| (*entry.key(), entry.value().clone())).collect()
    };

    // Close all connections within runtime context
    let _ = runtime.block_on(async {
        for (_id, connection) in connections_to_close {
            runtime.spawn(async move {
                connection.close(VarInt::from_u32(0), b"");
            });
        }

        for (_id, endpoint) in endpoints_to_idle {
            runtime.spawn(async move {
                let _ = endpoint.wait_idle().await;
            });
        }
    });

    // Clear all registries
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");
    connections.clear();

    let endpoints = ENDPOINTS.get().expect("Endpoint registry not initialized");
    endpoints.clear();

    let control_streams = CONTROL_STREAMS.get().expect("Control streams not initialized");
    control_streams.clear();

    let recv_buffers = RECV_BUFFERS.get().expect("Receive buffers not initialized");
    recv_buffers.clear();

    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");
    stream_writers.clear();

    let data_stream_buffers = DATA_STREAM_BUFFERS.get().expect("Data stream buffers not initialized");
    data_stream_buffers.clear();

    let active_data_streams = ACTIVE_DATA_STREAMS.get().expect("Active data streams not initialized");
    active_data_streams.clear();

    let datagram_buffers = DATAGRAM_BUFFERS.get().expect("Datagram buffers not initialized");
    datagram_buffers.clear();

    log::info!("MoQ QUIC transport cleanup complete");
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
pub extern "C" fn moq_quic_get_last_error(
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

/// Create a unidirectional data stream and write data (single-shot)
///
/// For MoQ data streams (not control messages)
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Number of bytes sent on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_send_data(
    connection_id: u64,
    data: *const u8,
    len: usize,
) -> i64 {
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");

    let connection = match connections.get(&connection_id) {
        Some(conn) => conn.clone(),
        None => {
            log::error!("Connection {} not found", connection_id);
            return -1;
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };
    let data_to_send = data_bytes.to_vec();

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        // Open unidirectional stream for data
        match connection.open_uni().await {
            Ok(mut send_stream) => {
                match send_stream.write_all(&data_to_send).await {
                    Ok(_) => {
                        match send_stream.finish() {
                            Ok(_) => {
                                log::debug!("Sent {} bytes on data stream for connection {}", len, connection_id);
                                len as i64
                            },
                            Err(e) => {
                                log::error!("Failed to finish data stream: {:?}", e);
                                -2
                            },
                        }
                    },
                    Err(e) => {
                        log::error!("Failed to write to data stream: {:?}", e);
                        -2
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to open data stream: {:?}", e);
                -2
            }
        }
    });

    result
}

// Counter for stream IDs within a connection
static NEXT_STREAM_ID: AtomicU64 = AtomicU64::new(1);

/// Open a persistent unidirectional stream for subgroup data
///
/// For MoQ publishing, each subgroup gets its own unidirectional stream.
/// The stream header is written when objects start being sent.
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `out_stream_id` - Output parameter for the stream ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_open_stream(
    connection_id: u64,
    out_stream_id: *mut u64,
) -> i32 {
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");
    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");

    let connection = match connections.get(&connection_id) {
        Some(conn) => conn.clone(),
        None => {
            log::error!("Connection {} not found for open_stream", connection_id);
            return -1;
        }
    };

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        match connection.open_uni().await {
            Ok(send_stream) => {
                let stream_id = NEXT_STREAM_ID.fetch_add(1, Ordering::SeqCst);

                // Create a persistent stream writer
                let writer = Arc::new(stream_writer::StreamWriter::new(
                    connection_id,
                    stream_id,
                    send_stream,
                    128, // Channel capacity for buffered writes
                ));

                stream_writers.insert((connection_id, stream_id), writer);

                log::debug!("Opened unidirectional stream {} for connection {}", stream_id, connection_id);
                Ok(stream_id)
            }
            Err(e) => {
                log::error!("Failed to open stream: {:?}", e);
                Err(-2)
            }
        }
    });

    match result {
        Ok(stream_id) => {
            unsafe { *out_stream_id = stream_id; }
            0
        }
        Err(code) => code
    }
}

/// Write data to an open stream
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `stream_id` - The stream ID from moq_quic_open_stream
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Number of bytes queued on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_stream_write(
    connection_id: u64,
    stream_id: u64,
    data: *const u8,
    len: usize,
) -> i64 {
    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");

    let writer = match stream_writers.get(&(connection_id, stream_id)) {
        Some(w) => w.clone(),
        None => {
            log::error!("Stream {} not found for connection {}", stream_id, connection_id);
            return -1;
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };
    let data_to_send = data_bytes.to_vec();

    match writer.try_write(data_to_send) {
        Ok(()) => {
            log::trace!("Queued {} bytes to stream {} for connection {}", len, stream_id, connection_id);
            len as i64
        }
        Err(e) => {
            log::error!("Failed to queue write to stream {}: {:?}", stream_id, e);
            -2
        }
    }
}

/// Finish/close an open stream
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `stream_id` - The stream ID from moq_quic_open_stream
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_stream_finish(
    connection_id: u64,
    stream_id: u64,
) -> i32 {
    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");

    // Remove the stream writer (this will trigger cleanup)
    let writer = match stream_writers.remove(&(connection_id, stream_id)) {
        Some((_, w)) => w,
        None => {
            log::warn!("Stream {} not found for finish on connection {}", stream_id, connection_id);
            return -1;
        }
    };

    match writer.try_finish() {
        Ok(()) => {
            log::debug!("Finished stream {} for connection {}", stream_id, connection_id);
            0
        }
        Err(e) => {
            log::error!("Failed to finish stream {}: {:?}", stream_id, e);
            -2
        }
    }
}

/// Get list of active incoming data streams for a connection
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `out_stream_ids` - Output array for stream IDs
/// * `max_streams` - Maximum number of stream IDs to return
///
/// # Returns
/// * Number of stream IDs written on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_get_data_streams(
    connection_id: u64,
    out_stream_ids: *mut u64,
    max_streams: usize,
) -> i32 {
    let active_streams = ACTIVE_DATA_STREAMS.get().expect("Active data streams not initialized");

    let streams_list = match active_streams.get(&connection_id) {
        Some(list) => list.clone(),
        None => {
            log::error!("Connection {} not found for get_data_streams", connection_id);
            return -1;
        }
    };

    if out_stream_ids.is_null() || max_streams == 0 {
        return 0;
    }

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let list = streams_list.lock().await;
        let count = list.len().min(max_streams);

        unsafe {
            let output = slice::from_raw_parts_mut(out_stream_ids, count);
            for (i, &stream_id) in list.iter().take(count).enumerate() {
                output[i] = stream_id;
            }
        }

        count as i32
    });

    result
}

/// Receive data from a specific data stream (non-blocking poll)
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `stream_id` - The data stream ID
/// * `buffer` - Pointer to buffer to store received data
/// * `buffer_len` - Length of buffer
///
/// # Returns
/// * Number of bytes received on success, 0 if no data available, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_recv_data(
    connection_id: u64,
    stream_id: u64,
    buffer: *mut u8,
    buffer_len: usize,
) -> i64 {
    let data_stream_buffers = DATA_STREAM_BUFFERS.get().expect("Data stream buffers not initialized");

    let stream_buffer = match data_stream_buffers.get(&(connection_id, stream_id)) {
        Some(rb) => rb.clone(),
        None => {
            log::trace!("Data stream {} not found for connection {}", stream_id, connection_id);
            return -1;
        }
    };

    if buffer.is_null() || buffer_len == 0 {
        return 0;
    }

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut recv_buf = stream_buffer.lock().await;

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

/// Close and clean up a data stream
///
/// Call this after the stream has been fully processed to free resources.
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `stream_id` - The data stream ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_close_data_stream(
    connection_id: u64,
    stream_id: u64,
) -> i32 {
    let data_stream_buffers = DATA_STREAM_BUFFERS.get().expect("Data stream buffers not initialized");
    let active_streams = ACTIVE_DATA_STREAMS.get().expect("Active data streams not initialized");

    // Remove the buffer
    data_stream_buffers.remove(&(connection_id, stream_id));

    // Remove from active streams list
    if let Some(streams_list) = active_streams.get(&connection_id) {
        let runtime = get_runtime();
        runtime.block_on(async {
            let mut list = streams_list.lock().await;
            list.retain(|&id| id != stream_id);
        });
    }

    log::debug!("Closed data stream {} for connection {}", stream_id, connection_id);
    0
}

/// Send a datagram (unreliable, unordered)
///
/// Datagrams are used for low-latency data that doesn't require
/// reliable delivery (e.g., audio frames in MoQ).
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Number of bytes sent on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_send_datagram(
    connection_id: u64,
    data: *const u8,
    len: usize,
) -> i64 {
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");

    let connection = match connections.get(&connection_id) {
        Some(conn) => conn.clone(),
        None => {
            log::error!("Connection {} not found for send_datagram", connection_id);
            return -1;
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };

    match connection.send_datagram(bytes::Bytes::copy_from_slice(data_bytes)) {
        Ok(()) => {
            log::trace!("Sent datagram ({} bytes) on connection {}", len, connection_id);
            len as i64
        }
        Err(e) => {
            log::error!("Failed to send datagram: {:?}", e);
            -2
        }
    }
}

/// Receive a datagram (non-blocking poll)
///
/// Returns the next complete datagram from the buffer, if available.
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `buffer` - Pointer to buffer to store received datagram
/// * `buffer_len` - Length of buffer
///
/// # Returns
/// * Number of bytes received on success, 0 if no datagram available, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_recv_datagram(
    connection_id: u64,
    buffer: *mut u8,
    buffer_len: usize,
) -> i64 {
    let datagram_buffers = DATAGRAM_BUFFERS.get().expect("Datagram buffers not initialized");

    let datagram_buffer = match datagram_buffers.get(&connection_id) {
        Some(buf) => buf.clone(),
        None => {
            log::error!("Connection {} not found for recv_datagram", connection_id);
            return -1;
        }
    };

    if buffer.is_null() || buffer_len == 0 {
        return 0;
    }

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let mut buf = datagram_buffer.lock().await;

        if let Some(datagram) = buf.pop_front() {
            let copy_len = datagram.len().min(buffer_len);
            unsafe {
                let output = slice::from_raw_parts_mut(buffer, copy_len);
                output.copy_from_slice(&datagram[..copy_len]);
            }
            if datagram.len() > buffer_len {
                log::warn!("Datagram truncated: {} bytes available, {} bytes buffer", datagram.len(), buffer_len);
            }
            copy_len as i64
        } else {
            0
        }
    });

    result
}
