// MoQ QUIC Transport using Quinn
// FFI bindings for Flutter/Dart

use quinn::{Endpoint, ClientConfig, Connection, VarInt, TokioRuntime, EndpointConfig};
use rustls::pki_types::CertificateDer;
use std::sync::{Arc, Mutex};
use std::net::SocketAddr;
use tokio::runtime::Runtime;
use std::ptr;
use std::slice;

// Connection handle opaque to Dart
#[repr(C)]
pub struct QuicConnectionHandle {
    conn: Arc<Mutex<Option<Connection>>>,
    runtime: Arc<Runtime>,
    read_buffer: Arc<Mutex<Vec<u8>>>,
}

// Global connection registry
static mut CONNECTIONS: Option<Vec<*mut QuicConnectionHandle>> = None;
static mut NEXT_ID: u64 = 1;

/// Initialize the QUIC transport module
#[no_mangle]
pub extern "C" fn moq_quic_init() {
    unsafe {
        CONNECTIONS = Some(Vec::new());
        NEXT_ID = 1;
    }
}

/// Create a new QUIC connection
///
/// # Arguments
/// * `host` - The hostname to connect to (must be null-terminated)
/// * `port` - The port to connect to
/// * `out_connection_id` - Output parameter for the connection ID
///
/// # Returns
/// * 0 on success, negative error code on failure
#[no_mangle]
pub extern "C" fn moq_quic_connect(
    host: *const i8,
    port: u16,
    out_connection_id: *mut u64,
) -> i32 {
    let host_str = unsafe {
        if host.is_null() {
            return -1; // Invalid host
        }
        match std::ffi::CStr::from_ptr(host).to_str() {
            Ok(s) => s,
            Err(_) => return -2, // Invalid UTF-8
        }
    };

    // Create runtime
    let runtime = match Runtime::new() {
        Ok(rt) => Arc::new(rt),
        Err(_) => return -3,
    };

    // Parse address
    let addr = match format!("{}:{}", host_str, port).parse::<SocketAddr>() {
        Ok(a) => a,
        Err(_) => return -4,
    };

    // Create client configuration
    let mut certs = rustls::RootCertStore::empty();
    let cert_result = rustls_native_certs::load_native_certs();
    // Access the certs field directly
    for cert in cert_result.certs {
        certs.add(cert).ok();
    }

    let config = ClientConfig::with_root_certificates(Arc::new(certs));

    // Create endpoint with a UDP socket
    let socket = match std::net::UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => s,
        Err(_) => return -5,
    };

    let endpoint = match Endpoint::new(
        EndpointConfig::default(),
        None, // No server config for client-only
        socket,
        Arc::new(TokioRuntime),
    ) {
        Ok(e) => e,
        Err(_) => return -6,
    };

    // Connect
    let connecting = match endpoint.connect(addr, host_str) {
        Ok(c) => c,
        Err(_) => return -6,
    };

    let connection = runtime.block_on(async {
        connecting.await
    });

    let connection = match connection {
        Ok(conn) => conn,
        Err(_) => return -7,
    };

    let handle = Arc::new(QuicConnectionHandle {
        conn: Arc::new(Mutex::new(Some(connection))),
        runtime,
        read_buffer: Arc::new(Mutex::new(Vec::new())),
    });

    // Register connection
    let id = unsafe {
        let ptr = Arc::into_raw(handle) as *mut QuicConnectionHandle;
        NEXT_ID += 1;
        CONNECTIONS.as_mut().unwrap().push(ptr);
        NEXT_ID - 1
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

    // Clone data to send
    let data_to_send = data_bytes.to_vec();

    let result = handle.runtime.block_on(async {
        let conn_guard = handle.conn.lock().unwrap();
        let connection = match conn_guard.as_ref() {
            Some(c) => c,
            None => return -2i64,
        };

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

/// Receive data from the QUIC connection (non-blocking)
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

    // Try to receive data (non-blocking check)
    let result: Result<Vec<u8>, std::io::Error> = handle.runtime.block_on(async {
        let conn_guard = handle.conn.lock().unwrap();
        let connection = match conn_guard.as_ref() {
            Some(c) => c,
            None => return Ok(Vec::new()),
        };

        // Accept incoming streams
        match connection.accept_uni().await {
            Ok(mut recv_stream) => {
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
            Err(_) => Ok(Vec::new()),
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

        // Close connection
        {
            let mut conn_guard = handle.conn.lock().unwrap();
            if let Some(conn) = conn_guard.take() {
                conn.close(VarInt::from_u32(0), b"");
            }
        }

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

/// Get last error message
/// Note: This is a simplified version - in production you'd want proper error handling
static mut LAST_ERROR: Option<String> = None;

#[no_mangle]
pub extern "C" fn moq_quic_get_error() -> *const i8 {
    unsafe {
        if let Some(ref err) = LAST_ERROR {
            err.as_ptr() as *const i8
        } else {
            std::ptr::null()
        }
    }
}

#[no_mangle]
pub extern "C" fn moq_quic_free_error(ptr: *mut i8) {
    if !ptr.is_null() {
        // Strings are managed by Rust - just clear the reference
        unsafe {
            LAST_ERROR = None;
        }
    }
}

fn set_error(msg: String) {
    unsafe {
        LAST_ERROR = Some(msg);
    }
}
