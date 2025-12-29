use std::env;
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;

fn main() {
    // Generate C header for FFI
    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    let header_path = out_path.join("moq_quic.h");
    let mut header = File::create(&header_path).unwrap();

    writeln!(header, "#ifndef MOQ_QUIC_H").unwrap();
    writeln!(header, "#define MOQ_QUIC_H").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "#ifdef __cplusplus").unwrap();
    writeln!(header, "extern \"C\" {{").unwrap();
    writeln!(header, "#endif").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Initialize the QUIC transport module").unwrap();
    writeln!(header, "void moq_quic_init(void);").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Create a new QUIC connection").unwrap();
    writeln!(header, "// Returns 0 on success, negative error code on failure").unwrap();
    writeln!(header, "int moq_quic_connect(").unwrap();
    writeln!(header, "    const char *host,").unwrap();
    writeln!(header, "    uint16_t port,").unwrap();
    writeln!(header, "    uint64_t *out_connection_id").unwrap();
    writeln!(header, ");").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Send data over the QUIC connection").unwrap();
    writeln!(header, "// Returns number of bytes sent on success, negative on error").unwrap();
    writeln!(header, "int64_t moq_quic_send(").unwrap();
    writeln!(header, "    uint64_t connection_id,").unwrap();
    writeln!(header, "    const uint8_t *data,").unwrap();
    writeln!(header, "    size_t len").unwrap();
    writeln!(header, ");").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Receive data from the QUIC connection (non-blocking)").unwrap();
    writeln!(header, "// Returns number of bytes received, 0 if no data, negative on error").unwrap();
    writeln!(header, "int64_t moq_quic_recv(").unwrap();
    writeln!(header, "    uint64_t connection_id,").unwrap();
    writeln!(header, "    uint8_t *buffer,").unwrap();
    writeln!(header, "    size_t buffer_len").unwrap();
    writeln!(header, ");").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Check if connection is established").unwrap();
    writeln!(header, "int moq_quic_is_connected(uint64_t connection_id);").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Close a QUIC connection").unwrap();
    writeln!(header, "int moq_quic_close(uint64_t connection_id);").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "// Cleanup the QUIC transport module").unwrap();
    writeln!(header, "void moq_quic_cleanup(void);").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "#ifdef __cplusplus").unwrap();
    writeln!(header, "}}").unwrap();
    writeln!(header, "#endif").unwrap();
    writeln!(header).unwrap();
    writeln!(header, "#endif // MOQ_QUIC_H").unwrap();

    // Tell cargo where to find the native libraries
    //if !cfg!(target_os = "windows") {
    //    println!("cargo:rustc-link-lib=stdc++");
    //}
    let target = std::env::var("TARGET").unwrap();
    if target.contains("apple") {
        // macOS uses libc++
        println!("cargo:rustc-link-lib=c++");
    } else if target.contains("linux") {
        // Linux uses libstdc++
        println!("cargo:rustc-link-lib=stdc++");
    } else if target.contains("windows") {
        // Windows (MSVC) doesn't need a manual stdc++ link; 
        // it uses default libs like msvcrt
    }
    
    println!("cargo:rerun-if-changed=src/lib.rs");

    // Copy header to include directory for easier access
    let include_path = PathBuf::from("native/moq_quic/include");
    std::fs::create_dir_all(&include_path).unwrap();
    std::fs::copy(&header_path, include_path.join("moq_quic.h")).ok();
}
