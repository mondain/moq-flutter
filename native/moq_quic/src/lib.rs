// MoQ QUIC Transport using Quinn
// FFI bindings for Flutter/Dart

use quinn::{Endpoint, ClientConfig, Connection, VarInt, TokioRuntime, EndpointConfig, TransportConfig};
use quinn::crypto::rustls::QuicClientConfig;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::crypto::CryptoProvider;
use std::sync::{Arc, Mutex};
use std::time;
use tokio::runtime::Runtime;
use std::ptr;
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

// Connection handle opaque to Dart
#[repr(C)]
pub struct QuicConnectionHandle {
    conn: Arc<Mutex<Option<Connection>>>,
    endpoint: Arc<Mutex<Option<Endpoint>>>,
    read_buffer: Arc<Mutex<Vec<u8>>>,
}

// Global runtime (single instance for all connections)
static mut GLOBAL_RUNTIME: Option<Runtime> = None;

// Global connection registry
static mut CONNECTIONS: Option<Vec<*mut QuicConnectionHandle>> = None;
static mut NEXT_ID: u64 = 1;

fn get_runtime() -> &'static Runtime {
    unsafe {
        if GLOBAL_RUNTIME.is_none() {
            GLOBAL_RUNTIME = Some(
                Runtime::new().expect("Failed to create Tokio runtime")
            );
        }
        GLOBAL_RUNTIME.as_ref().unwrap()
    }
}

/// Initialize the QUIC transport module
#[no_mangle]
pub extern "C" fn moq_quic_init() {
    // Install default CryptoProvider for rustls (required for rustls 0.23+)
    // Use aws-lc-rs provider for better cross-platform support (especially macOS)
    #[cfg(feature = "aws-lc-rs")]
    let provider = rustls::crypto::aws_lc_rs::default_provider();
    #[cfg(not(feature = "aws-lc-rs"))]
    let provider = rustls::crypto::ring::default_provider();
    let _ = CryptoProvider::install_default(provider);

    unsafe {
        if GLOBAL_RUNTIME.is_none() {
            GLOBAL_RUNTIME = Some(Runtime::new().expect("Failed to create Tokio runtime"));
        }
        CONNECTIONS = Some(Vec::new());
        NEXT_ID = 0;  // Start at 0 for 0-based indexing
    }
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
                eprintln!("DNS resolution error for {}: {:?}", addr_str, e);
                return Err(-4);
            }
        };

        // Use the first resolved address
        let addr = match addrs.into_iter().next() {
            Some(a) => a,
            None => return Err(-4),
        };

        // Create client configuration
        // For production, you should add actual root certificates
        // For development/testing, use insecure mode to skip certificate verification
        let certs = rustls::RootCertStore::empty();

        // Build transport config with standard settings (from moq-native-ietf)
        let mut transport = TransportConfig::default();
        transport.max_idle_timeout(Some(time::Duration::from_secs(10).try_into().unwrap()));
        transport.keep_alive_interval(Some(time::Duration::from_secs(4)));

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
                eprintln!("QuicClientConfig error: {:?}", e);
                return Err(-6);
            }
        };
        let mut client_config = ClientConfig::new(Arc::new(crypto));
        client_config.transport_config(Arc::new(transport));

        // Create endpoint with a UDP socket (std::net::UdpSocket, not tokio)
        let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
            Ok(s) => s,
            Err(e) => {
                eprintln!("UDP bind error: {:?}", e);
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
                eprintln!("Endpoint creation error: {:?}", e);
                return Err(-6);
            }
        };

        // Set the default client config
        endpoint.set_default_client_config(client_config);

        // Connect
        let connecting = match endpoint.connect(addr, &host_str) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("Connect error: {:?}", e);
                return Err(-6);
            }
        };

        let connection = connecting.await;

        let connection = match connection {
            Ok(conn) => conn,
            Err(e) => {
                eprintln!("Connection await error: {:?}", e);
                return Err(-7);
            }
        };

        Ok((endpoint, connection, host_str))
    });

    let (endpoint, connection, _host_str) = match result {
        Ok((e, c, h)) => (e, c, h),
        Err(e) => return e,
    };

    let handle = Arc::new(QuicConnectionHandle {
        conn: Arc::new(Mutex::new(Some(connection))),
        endpoint: Arc::new(Mutex::new(Some(endpoint))),
        read_buffer: Arc::new(Mutex::new(Vec::new())),
    });

    // Register connection (use 0-based indexing)
    let id = unsafe {
        let ptr = Arc::into_raw(handle) as *mut QuicConnectionHandle;
        let id = NEXT_ID;
        NEXT_ID += 1;
        CONNECTIONS.as_mut().unwrap().push(ptr);
        id
    };

    unsafe {
        *out_connection_id = id;
    }

    0
}

/// Send data over the QUIC connection
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
    let handle = unsafe {
        match CONNECTIONS.as_ref().and_then(|v| v.get(connection_id as usize)) {
            Some(&h) => &*h,
            None => return -1,
        }
    };

    let data_bytes = unsafe { slice::from_raw_parts(data, len) };
    let data_to_send = data_bytes.to_vec();

    let runtime = get_runtime();

    let result = runtime.block_on(async {
        let conn_guard = handle.conn.lock().unwrap();
        let connection = match conn_guard.as_ref() {
            Some(c) => c.clone(),
            None => return -2i64,
        };
        drop(conn_guard);

        // Open unidirectional stream for sending
        match connection.open_uni().await {
            Ok(mut send_stream) => {
                match send_stream.write_all(&data_to_send).await {
                    Ok(_) => match send_stream.finish() {
                        Ok(_) => len as i64,
                        Err(_) => -2,
                    },
                    Err(_) => -2,
                }
            }
            Err(_) => -2,
        }
    });

    result
}

/// Receive data from the QUIC connection (non-blocking with timeout)
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
    buffer: *mut u8,
    buffer_len: usize,
) -> i64 {
    let handle = unsafe {
        match CONNECTIONS.as_ref().and_then(|v| v.get(connection_id as usize)) {
            Some(&h) => &*h,
            None => return -1,
        }
    };

    let runtime = get_runtime();

    // Try to receive data with a short timeout
    let result: Result<Vec<u8>, Box<dyn std::error::Error>> = runtime.block_on(async {
        let conn_guard = handle.conn.lock().unwrap();
        let connection = match conn_guard.as_ref() {
            Some(c) => c.clone(),
            None => return Ok(Vec::new()),
        };
        drop(conn_guard);

        // Use timeout to avoid blocking indefinitely
        match tokio::time::timeout(
            tokio::time::Duration::from_millis(10),
            connection.accept_uni(),
        ).await {
            Ok(Ok(mut recv_stream)) => {
                match recv_stream.read_to_end(4096).await {
                    Ok(data) => {
                        if !data.is_empty() {
                            Ok(data)
                        } else {
                            Ok(Vec::new())
                        }
                    }
                    Err(_) => Ok(Vec::new()),
                }
            }
            _ => Ok(Vec::new()),
        }
    });

    match result {
        Ok(data) => {
            let len = data.len().min(buffer_len);
            if len > 0 {
                unsafe {
                    ptr::copy_nonoverlapping(data.as_ptr(), buffer, len);
                }
            }
            len as i64
        }
        Err(_) => -2,
    }
}

/// Check if connection is established
#[no_mangle]
pub extern "C" fn moq_quic_is_connected(connection_id: u64) -> i32 {
    let handle = unsafe {
        match CONNECTIONS.as_ref().and_then(|v| v.get(connection_id as usize)) {
            Some(&h) => &*h,
            None => return 0,
        }
    };

    let conn_guard = handle.conn.lock().unwrap();
    if conn_guard.is_some() {
        1
    } else {
        0
    }
}

/// Close a QUIC connection
#[no_mangle]
pub extern "C" fn moq_quic_close(connection_id: u64) -> i32 {
    let handle_opt = unsafe {
        CONNECTIONS.as_mut().and_then(|v| v.get_mut(connection_id as usize))
    };

    if let Some(handle_ptr) = handle_opt {
        let handle = unsafe { &**handle_ptr };
        let runtime = get_runtime();

        // Close connection within runtime context
        let _ = runtime.block_on(async {
            let mut conn_guard = handle.conn.lock().unwrap();
            let mut endpoint_guard = handle.endpoint.lock().unwrap();

            if let Some(conn) = conn_guard.take() {
                conn.close(VarInt::from_u32(0), b"");
            }

            // Clean up endpoint
            if let Some(endpoint) = endpoint_guard.take() {
                endpoint.wait_idle().await;
            }
        });

        // Remove from registry
        unsafe {
            let _ = Box::from_raw(*handle_ptr);
            CONNECTIONS.as_mut().unwrap().retain(|&p| p as usize != connection_id as usize);
        }

        0
    } else {
        -1
    }
}

/// Cleanup the QUIC transport module
#[no_mangle]
pub extern "C" fn moq_quic_cleanup() {
    let runtime = get_runtime();

    // Close all connections within runtime context
    let _ = runtime.block_on(async {
        unsafe {
            if let Some(conns) = CONNECTIONS.as_ref() {
                for ptr in conns.iter() {
                    let handle = &**ptr;
                    let mut conn_guard = handle.conn.lock().unwrap();
                    let mut endpoint_guard = handle.endpoint.lock().unwrap();

                    if let Some(conn) = conn_guard.take() {
                        conn.close(VarInt::from_u32(0), b"");
                    }

                    if let Some(endpoint) = endpoint_guard.take() {
                        let _ = endpoint.wait_idle().await;
                    }
                }
            }
        }
    });

    unsafe {
        if let Some(conns) = CONNECTIONS.as_mut() {
            for ptr in conns.iter() {
                let _ = Box::from_raw(*ptr);
            }
            conns.clear();
        }
        CONNECTIONS = None;
    }
}
