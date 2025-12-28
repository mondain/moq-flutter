import 'dart:io';

/// Build hook to compile the Rust QUIC library
void main(List<String> args) async {
  // Parse build mode from arguments
  final buildMode = args.firstWhere(
    (arg) => arg.startsWith('--build-mode='),
    orElse: () => '--build-mode=release',
  );

  final isDebug = buildMode.contains('debug');
  print('Building Rust library (mode: ${isDebug ? "debug" : "release"})');

  // Get the project root directory
  final projectRoot = Directory.current.path;

  // Compile for the current platform
  await _compileRustLibrary(
    projectRoot: projectRoot,
    isDebug: isDebug,
  );

  print('Rust library build completed successfully');
  exit(0);
}

Future<void> _compileRustLibrary({
  required String projectRoot,
  required bool isDebug,
}) async {
  final rustDir = '$projectRoot/native/moq_quic';

  // Check if rust directory exists
  if (!Directory(rustDir).existsSync()) {
    print('Warning: Rust directory not found: $rustDir');
    print('Skipping Rust library compilation');
    return;
  }

  // Check if cargo is available
  if (!await _checkCommand('cargo', ['--version'])) {
    print('Warning: Cargo not found. Skipping Rust library compilation.');
    print('Please install Rust from https://rustup.rs/');
    return;
  }

  // Platform-specific compilation
  final platform = Platform.operatingSystem;

  switch (platform) {
    case 'linux':
      await _compileLinux(rustDir, isDebug);
      break;
    case 'macos':
      await _compileMacOS(rustDir, isDebug);
      break;
    case 'windows':
      await _compileWindows(rustDir, isDebug);
      break;
    case 'android':
      // Android compilation is handled separately via Gradle
      print('Android build: Rust compilation will be handled by Gradle');
      return;
    case 'ios':
      // iOS compilation is handled separately via Xcode
      print('iOS build: Rust compilation will be handled by Xcode');
      return;
    default:
      print('Warning: Unsupported platform: $platform');
      return;
  }

  print('Rust library compiled successfully for $platform');
}

Future<void> _compileLinux(String rustDir, bool isDebug) async {
  print('Compiling for Linux...');

  final args = ['build', '--lib', '--profile', isDebug ? 'dev' : 'release'];

  final result = await Process.run(
    'cargo',
    args,
    workingDirectory: rustDir,
    environment: {
      'CARGO_TERM_COLOR': 'always',
    },
  );

  if (result.exitCode != 0) {
    print('Cargo build failed:\n${result.stderr}');
    throw BuildException('Failed to compile Rust library for Linux');
  }

  print('Linux library compiled successfully');
}

Future<void> _compileMacOS(String rustDir, bool isDebug) async {
  print('Compiling for macOS...');

  // Target universal macOS binary (both arm64 and x86_64)
  final targets = ['aarch64-apple-darwin', 'x86_64-apple-darwin'];

  for (final target in targets) {
    if (!await _checkRustTarget(target)) {
      print('Installing Rust target: $target');
      await Process.run('rustup', ['target', 'add', target]);
    }
  }

  // Build for each target
  for (final target in targets) {
    final args = [
      'build',
      '--lib',
      '--target',
      target,
      if (!isDebug) '--release',
    ];

    final result = await Process.run(
      'cargo',
      args,
      workingDirectory: rustDir,
      environment: {
        'CARGO_TERM_COLOR': 'always',
      },
    );

    if (result.exitCode != 0) {
      print('Cargo build failed for $target:\n${result.stderr}');
      throw BuildException('Failed to compile Rust library for macOS');
    }
  }

  // Create universal binary
  final buildType = isDebug ? 'debug' : 'release';
  final arm64Lib = '$rustDir/target/aarch64-apple-darwin/$buildType/libmoq_quic.a';
  final x64Lib = '$rustDir/target/x86_64-apple-darwin/$buildType/libmoq_quic.a';
  final universalLib = '$rustDir/target/universal-apple-darwin/$buildType/libmoq_quic.a';

  Directory('$rustDir/target/universal-apple-darwin/$buildType')
      .createSync(recursive: true);

  await Process.run(
    'lipo',
    ['-create', '-output', universalLib, arm64Lib, x64Lib],
  );

  print('Universal binary created: $universalLib');
}

Future<void> _compileWindows(String rustDir, bool isDebug) async {
  print('Compiling for Windows...');

  final args = ['build', '--lib', if (!isDebug) '--release'];

  final result = await Process.run(
    'cargo',
    args,
    workingDirectory: rustDir,
    environment: {
      'CARGO_TERM_COLOR': 'always',
    },
  );

  if (result.exitCode != 0) {
    print('Cargo build failed:\n${result.stderr}');
    throw BuildException('Failed to compile Rust library for Windows');
  }

  print('Windows library compiled successfully');
}

Future<bool> _checkCommand(String command, List<String> args) async {
  try {
    final result = await Process.run(command, args);
    return result.exitCode == 0;
  } catch (e) {
    return false;
  }
}

Future<bool> _checkRustTarget(String target) async {
  final result = await Process.run('rustup', ['target', 'list', '--installed']);
  return result.stdout.toString().contains(target);
}

/// Exception thrown when build fails
class BuildException implements Exception {
  final String message;
  BuildException(this.message);

  @override
  String toString() => 'BuildException: $message';
}
