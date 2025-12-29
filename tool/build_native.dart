import 'dart:io';

/// Build script that ensures the native QUIC library is built before Flutter build
/// Run this with: dart run tool/build_native.dart
Future<void> main() async {
  final scriptDir = File(Platform.script.toFilePath()).parent.parent.path;
  final nativeDir = '$scriptDir/native/moq_quic';

  stdout.writeln('Building native QUIC library...');

  if (Platform.isWindows) {
    final result = await Process.run(
      'cargo',
      ['build', '--release', '--manifest-path', '$nativeDir/Cargo.toml'],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      stderr.writeln('Build failed');
      stderr.writeln(result.stderr);
      exit(result.exitCode);
    }
    stdout.writeln('✓ Built: moq_quic.dll');
  } else if (Platform.isMacOS) {
    // Build universal binary for macOS
    stdout.writeln('Building for macOS (universal)...');

    // Build x86_64
    stdout.writeln('Building x86_64...');
    final x86Result = await Process.run(
      'cargo',
      ['build', '--release', '--target', 'x86_64-apple-darwin', '--manifest-path', '$nativeDir/Cargo.toml'],
      runInShell: true,
    );

    if (x86Result.exitCode != 0) {
      stderr.writeln('Failed to build x86_64');
      stderr.writeln(x86Result.stderr);
      exit(1);
    }

    // Build arm64
    stdout.writeln('Building arm64...');
    final armResult = await Process.run(
      'cargo',
      ['build', '--release', '--target', 'aarch64-apple-darwin', '--manifest-path', '$nativeDir/Cargo.toml'],
      runInShell: true,
    );

    if (armResult.exitCode != 0) {
      stderr.writeln('Failed to build arm64');
      stderr.writeln(armResult.stderr);
      exit(1);
    }

    // Create universal binary
    stdout.writeln('Creating universal binary...');
    Directory('$nativeDir/target/release').create(recursive: true);

    final lipoResult = await Process.run(
      'lipo',
      [
        '-create',
        '$nativeDir/target/x86_64-apple-darwin/release/libmoq_quic.dylib',
        '$nativeDir/target/aarch64-apple-darwin/release/libmoq_quic.dylib',
        '-output',
        '$nativeDir/target/release/libmoq_quic.dylib',
      ],
      runInShell: true,
    );

    if (lipoResult.exitCode != 0) {
      stderr.writeln('Failed to create universal binary');
      stderr.writeln(lipoResult.stderr);
      exit(1);
    }
    stdout.writeln('✓ Built: libmoq_quic.dylib (universal)');
  } else if (Platform.isLinux) {
    final result = await Process.run(
      'cargo',
      ['build', '--release', '--manifest-path', '$nativeDir/Cargo.toml'],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      stderr.writeln('Build failed');
      stderr.writeln(result.stderr);
      exit(result.exitCode);
    }
    stdout.writeln('✓ Built: libmoq_quic.so');
  } else {
    stderr.writeln('Unsupported platform: ${Platform.operatingSystem}');
    exit(1);
  }

  stdout.writeln('✓ Native library built successfully');
}
