// MoQ QUIC Transport using Quinn
// FFI bindings for Flutter/Dart
//
// Architecture:
// - DashMap for thread-safe connection/stream registry
// - mpsc channels for async stream writes
// - Spawning tasks for stream handling (no polling)
// - Incremental reading for large streams

mod stream_writer;

use quinn::{Endpoint, ClientConfig, Connection, VarInt, TokioRuntime, EndpointConfig, TransportConfig};
use quinn::crypto::rustls::QuicClientConfig;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::crypto::CryptoProvider;
use dashmap::DashMap;
use once_cell::sync::OnceCell;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time;
use tokio::runtime::Runtime;
use std::slice;

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

// Global Tokio runtime for async operations
static RUNTIME: OnceCell<Runtime> = OnceCell::new();

// Global registry of Quinn connections (connection_id -> connection)
static CONNECTIONS: OnceCell<DashMap<u64, Arc<Connection>>> = OnceCell::new();

// Global registry of endpoints (connection_id -> endpoint)
static ENDPOINTS: OnceCell<DashMap<u64, Arc<Endpoint>>> = OnceCell::new();

// Global registry of stream writers (connection_id -> stream_id -> writer)
static STREAM_WRITERS: OnceCell<DashMap<(u64, u64), Arc<stream_writer::StreamWriter>>> = OnceCell::new();

// Next connection ID counter
static NEXT_CONNECTION_ID: AtomicU64 = AtomicU64::new(1);

// Next unidirectional stream ID counter (for server-initiated streams)
// Starts from 100000 to avoid collisions with accepted streams
static NEXT_UNI_STREAM_ID: AtomicU64 = AtomicU64::new(100000);

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

    // Initialize stream writers registry
    if STREAM_WRITERS.set(DashMap::new()).is_err() {
        log::warn!("Stream writers registry already initialized");
    }

    log::info!("MoQ QUIC transport initialized");
}

/// Create a new QUIC connection
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
    host: *const i8,
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
                log::error!("DNS resolution error for {}: {:?}", addr_str, e);
                return Err(-4);
            }
        };

        // Use the first resolved address
        let addr = match addrs.into_iter().next() {
            Some(a) => a,
            None => return Err(-4),
        };

        // Create client configuration with proper transport settings
        let certs = rustls::RootCertStore::empty();

        // Build transport config with standard settings (from moq-native-ietf)
        let mut transport = TransportConfig::default();
        transport.max_idle_timeout(Some(time::Duration::from_secs(30).try_into().unwrap()));
        transport.keep_alive_interval(Some(time::Duration::from_secs(4)));
        transport.max_concurrent_bidi_streams(100u32.into());
        transport.max_concurrent_uni_streams(100u32.into());

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
                log::error!("QuicClientConfig error: {:?}", e);
                return Err(-6);
            }
        };
        let mut client_config = ClientConfig::new(Arc::new(crypto));
        client_config.transport_config(Arc::new(transport));

        // Create endpoint with a UDP socket (std::net::UdpSocket, not tokio)
        let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                log::error!("UDP bind error: {:?}", e);
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
                log::error!("Endpoint creation error: {:?}", e);
                return Err(-6);
            }
        };

        // Set the default client config
        endpoint.set_default_client_config(client_config);

        // Connect
        let connecting = match endpoint.connect(addr, &host_str) {
            Ok(c) => c,
            Err(e) => {
                log::error!("Connect error: {:?}", e);
                return Err(-6);
            }
        };

        let connection = match connecting.await {
            Ok(conn) => conn,
            Err(e) => {
                log::error!("Connection await error: {:?}", e);
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

    let connection_arc = Arc::new(connection);
    let endpoint_arc = Arc::new(endpoint);

    connections.insert(connection_id, connection_arc.clone());
    endpoints.insert(connection_id, endpoint_arc);

    // Start accepting streams immediately - spawn task
    let connection_for_accept = connection_arc.clone();
    runtime.spawn(async move {
        handle_connection_streams(connection_id, connection_for_accept).await;
    });

    unsafe {
        *out_connection_id = connection_id;
    }

    log::info!("QUIC connection established (ID: {})", connection_id);
    0
}

/// Handle incoming streams for a connection
async fn handle_connection_streams(connection_id: u64, connection: Arc<Connection>) {
    log::info!("Connection {} accept loop started", connection_id);

    loop {
        tokio::select! {
            // Accept unidirectional streams
            result = connection.accept_uni() => {
                match result {
                    Ok(recv_stream) => {
                        let stream_id = recv_stream.id().index();
                        log::info!("Connection {} accepted unidirectional stream: {}", connection_id, stream_id);

                        // Spawn task to handle this stream
                        tokio::spawn(async move {
                            handle_unidirectional_stream_internal(connection_id, stream_id, recv_stream).await;
                        });
                    }
                    Err(e) => {
                        log::warn!("Connection {} accept_uni error: {:?}", connection_id, e);
                        break;
                    }
                }
            }
            // Accept bidirectional streams
            result = connection.accept_bi() => {
                match result {
                    Ok((send_stream, recv_stream)) => {
                        let stream_id = send_stream.id().index();
                        log::info!("Connection {} accepted bidirectional stream: {}", connection_id, stream_id);

                        // Spawn task to handle this stream
                        tokio::spawn(async move {
                            handle_bidirectional_stream_internal(connection_id, stream_id, send_stream, recv_stream).await;
                        });
                    }
                    Err(e) => {
                        log::warn!("Connection {} accept_bi error: {:?}", connection_id, e);
                        break;
                    }
                }
            }
        }
    }

    log::info!("Connection {} accept loop exited", connection_id);

    // Notify through callback (in real implementation, would call Dart)
    // For now, just log
}

/// Handle a unidirectional stream with incremental reading
async fn handle_unidirectional_stream_internal(
    connection_id: u64,
    stream_id: u64,
    mut recv_stream: quinn::RecvStream,
) {
    let mut buffer = vec![0u8; 65536]; // 64KB read buffer

    loop {
        match recv_stream.read(&mut buffer).await {
            Ok(Some(len)) => {
                log::debug!("Uni stream {}:{} received {} bytes", connection_id, stream_id, len);

                // In real implementation, would callback to Dart here
                // For now, just log the data
                if len <= 100 {
                    let hex: String = buffer[..len].iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
                    log::info!("Data: [{}]", hex);
                } else {
                    log::info!("Data: {} bytes (truncated)", len);
                }
            }
            Ok(None) => {
                log::debug!("Uni stream {}:{} closed", connection_id, stream_id);
                break;
            }
            Err(e) => {
                log::error!("Error reading from uni stream {}:{}: {:?}", connection_id, stream_id, e);
                break;
            }
        }
    }
}

/// Handle a bidirectional stream with incremental reading
async fn handle_bidirectional_stream_internal(
    connection_id: u64,
    stream_id: u64,
    send_stream: quinn::SendStream,
    mut recv_stream: quinn::RecvStream,
) {
    // Create stream writer for the send side
    let writer = stream_writer::StreamWriter::new(
        connection_id,
        stream_id,
        send_stream,
        50, // Channel capacity
    );

    // Register in global registry
    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");
    stream_writers.insert((connection_id, stream_id), Arc::new(writer));

    // Read data incrementally
    let mut buffer = vec![0u8; 65536]; // 64KB read buffer

    loop {
        match recv_stream.read(&mut buffer).await {
            Ok(Some(len)) => {
                log::debug!("Bi stream {}:{} received {} bytes", connection_id, stream_id, len);

                // In real implementation, would callback to Dart here
                if len <= 100 {
                    let hex: String = buffer[..len].iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
                    log::info!("Data: [{}]", hex);
                } else {
                    log::info!("Data: {} bytes (truncated)", len);
                }
            }
            Ok(None) => {
                log::debug!("Bi stream {}:{} closed", connection_id, stream_id);
                break;
            }
            Err(e) => {
                log::error!("Error reading from bi stream {}:{}: {:?}", connection_id, stream_id, e);
                break;
            }
        }
    }

    // Clean up stream writer
    stream_writers.remove(&(connection_id, stream_id));
}

/// Send data over a unidirectional stream
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
        // Open unidirectional stream for sending
        match connection.open_uni().await {
            Ok(mut send_stream) => {
                match send_stream.write_all(&data_to_send).await {
                    Ok(_) => {
                        match send_stream.finish() {
                            Ok(_) => {
                                log::info!("Sent {} bytes on connection {}", len, connection_id);
                                len as i64
                            },
                            Err(e) => {
                                log::error!("Failed to finish stream: {:?}", e);
                                -2
                            },
                        }
                    },
                    Err(e) => {
                        log::error!("Failed to write to stream: {:?}", e);
                        -2
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to open unidirectional stream: {:?}", e);
                -2
            }
        }
    });

    result
}

/// Receive data from the QUIC connection (non-blocking, immediate return)
///
/// Note: This is now a polling interface for Dart compatibility.
/// The actual receive loop runs in spawned tasks that handle streams asynchronously.
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `buffer` - Buffer to receive data
/// * `buffer_len` - Length of buffer
///
/// # Returns
/// * Number of bytes received on success, 0 if no data available, negative on error
#[no_mangle]
pub extern "C" fn moq_quic_recv(
    connection_id: u64,
    _buffer: *mut u8,
    _buffer_len: usize,
) -> i64 {
    // With the new async architecture, data is received through callbacks
    // This function is kept for FFI compatibility but returns 0 (no polling)
    // Real data comes through the callback mechanism

    // Check if connection exists
    let connections = CONNECTIONS.get().expect("Connection registry not initialized");
    if !connections.contains_key(&connection_id) {
        return -1;
    }

    // No polling data available - use callback mechanism instead
    0
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

    // Clean up stream writers for this connection
    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");
    stream_writers.retain(|key, _| key.0 != connection_id);

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

    let stream_writers = STREAM_WRITERS.get().expect("Stream writers not initialized");
    stream_writers.clear();

    log::info!("MoQ QUIC transport cleanup complete");
}

/// Create a unidirectional stream and write initial data
///
/// # Arguments
/// * `connection_id` - The connection ID
/// * `data` - Pointer to data to send
/// * `len` - Length of data
///
/// # Returns
/// * Stream ID on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_open_uni(
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

    // Generate synthetic stream ID
    let stream_id = NEXT_UNI_STREAM_ID.fetch_add(1, Ordering::SeqCst);

    // Spawn task to open stream and write data
    runtime.spawn(async move {
        match connection.open_uni().await {
            Ok(mut send_stream) => {
                log::info!("Opened uni stream {}:{} for sending", connection_id, stream_id);

                match send_stream.write_all(&data_to_send).await {
                    Ok(_) => {
                        match send_stream.finish() {
                            Ok(_) => {
                                log::info!("Sent {} bytes on uni stream {}:{}", len, connection_id, stream_id);
                            }
                            Err(e) => {
                                log::error!("Failed to finish uni stream {}:{}: {:?}", connection_id, stream_id, e);
                            }
                        }
                    }
                    Err(e) => {
                        log::error!("Failed to write to uni stream {}:{}: {:?}", connection_id, stream_id, e);
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to open uni stream {}:{}: {:?}", connection_id, stream_id, e);
            }
        }
    });

    stream_id as i64
}
