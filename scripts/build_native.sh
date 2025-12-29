#!/bin/bash
# Build script for native QUIC library (Linux/macOS)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
NATIVE_DIR="$PROJECT_ROOT/native/moq_quic"

echo "Building native QUIC library..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - build universal binary (x86_64 + arm64)
    echo "Building for macOS (universal)..."

    # Build for x86_64
    echo "Building x86_64..."
    cargo build --release --target x86_64-apple-darwin --manifest-path "$NATIVE_DIR/Cargo.toml"

    # Build for arm64
    echo "Building arm64..."
    cargo build --release --target aarch64-apple-darwin --manifest-path "$NATIVE_DIR/Cargo.toml"

    # Create universal binary
    echo "Creating universal binary..."
    mkdir -p "$NATIVE_DIR/target/release"
    lipo -create \
        "$NATIVE_DIR/target/x86_64-apple-darwin/release/libmoq_quic.dylib" \
        "$NATIVE_DIR/target/aarch64-apple-darwin/release/libmoq_quic.dylib" \
        -output "$NATIVE_DIR/target/release/libmoq_quic.dylib"

    echo "✓ Built: libmoq_quic.dylib (universal)"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    echo "Building for Linux..."
    cargo build --release --manifest-path "$NATIVE_DIR/Cargo.toml"
    echo "✓ Built: libmoq_quic.so"
else
    echo "Unsupported OS: $OSTYPE"
    exit 1
fi
