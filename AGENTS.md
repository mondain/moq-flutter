# Repository Guidelines

## Project Structure & Module Organization
- `lib/`: Flutter/Dart source (client, protocol, media, UI, providers).
- `native/moq_quic/`: Rust QUIC library used via FFI.
- `test/`: Dart unit tests (protocol serialization lives in `test/moq/protocol/`).
- `scripts/` and `tool/`: build helpers for native components.
- Platform folders (`android/`, `ios/`, `macos/`, `linux/`, `windows/`, `web/`): Flutter host projects.
- `docs/`: reference specs and drafts.

## Build, Test, and Development Commands
- `flutter pub get`: install Dart/Flutter dependencies.
- `flutter run`: run the app; triggers native Rust build hooks.
- `flutter build <platform>`: produce platform artifacts (e.g., `apk`, `ios`, `macos`, `linux`, `windows`).
- `flutter test`: run all Dart tests.
- `flutter analyze`: run static analysis with `flutter_lints`.
- `cd native/moq_quic && cargo build --release`: build the Rust library manually.
- `scripts/build_native.sh` (Linux/macOS/iOS) or `scripts/build_native.bat` (Windows): manual native builds.

## Coding Style & Naming Conventions
- Follow standard Dart style (2-space indentation, trailing commas for auto-formatting).
- Keep Dart files lower_snake_case (e.g., `moq_messages_data.dart`).
- Use `flutter_lints` via `analysis_options.yaml`; avoid disabling lints unless justified.
- Prefer Riverpod conventions for providers (see `lib/providers/`).

## Testing Guidelines
- Primary framework: `flutter_test`.
- Place new tests under `test/` and mirror `lib/` paths when possible.
- Naming: `<feature>_test.dart` (e.g., `wire_format_test.dart`).
- Run targeted tests with `flutter test test/moq/protocol/wire_format_test.dart`.

## Commit & Pull Request Guidelines
- Commit subjects are short, imperative, and sentence case (e.g., “Add replay buffer…”).
- Keep commits focused; mention protocol or platform impact in the body if needed.
- PRs should include: summary, testing performed, and screenshots for UI changes.

## Configuration & Notes
- Rust builds are wired into Flutter via `tool/build_rust.dart` and platform build hooks.
- Specs and protocol notes live in `docs/` for reference when touching protocol code.
