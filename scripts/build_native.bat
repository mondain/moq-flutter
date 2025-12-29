@echo off
REM Build script for native QUIC library (Windows)

setlocal

set "SCRIPT_DIR=%~dp0"
set "PROJECT_ROOT=%SCRIPT_DIR%.."
set "NATIVE_DIR=%PROJECT_ROOT%\native\moq_quic"

echo Building native QUIC library for Windows...

cargo build --release --manifest-path "%NATIVE_DIR%\Cargo.toml"

if %ERRORLEVEL% NEQ 0 (
    echo Build failed
    exit /b %ERRORLEVEL%
)

echo ✓ Built: moq_quic.dll
