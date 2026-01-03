import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/moq_providers.dart';

/// Service for persisting app settings to local storage
class SettingsService {
  final SharedPreferences _prefs;

  SettingsService(this._prefs);

  // Keys for settings
  static const _keyThemeMode = 'theme_mode';
  static const _keyVideoResolution = 'video_resolution';
  static const _keyPackagingFormat = 'packaging_format';
  static const _keyTransportType = 'transport_type';

  // Theme mode
  ThemeMode get themeMode {
    final value = _prefs.getString(_keyThemeMode);
    return ThemeMode.values.firstWhere(
      (e) => e.name == value,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _prefs.setString(_keyThemeMode, mode.name);
  }

  // Video resolution
  VideoResolution get videoResolution {
    final value = _prefs.getString(_keyVideoResolution);
    return VideoResolution.values.firstWhere(
      (e) => e.name == value,
      orElse: () => VideoResolution.r720p,
    );
  }

  Future<void> setVideoResolution(VideoResolution resolution) async {
    await _prefs.setString(_keyVideoResolution, resolution.name);
  }

  // Packaging format
  PackagingFormat get packagingFormat {
    final value = _prefs.getString(_keyPackagingFormat);
    return PackagingFormat.values.firstWhere(
      (e) => e.name == value,
      orElse: () => PackagingFormat.moqMi,
    );
  }

  Future<void> setPackagingFormat(PackagingFormat format) async {
    await _prefs.setString(_keyPackagingFormat, format.name);
  }

  // Transport type
  TransportType get transportType {
    final value = _prefs.getString(_keyTransportType);
    return TransportType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TransportType.moqt,
    );
  }

  Future<void> setTransportType(TransportType type) async {
    await _prefs.setString(_keyTransportType, type.name);
  }

  // Connection settings keys
  static const _keyHost = 'host';
  static const _keyPort = 'port';
  static const _keyUrl = 'url';
  static const _keyInsecureMode = 'insecure_mode';
  static const _keyNamespace = 'namespace';
  static const _keyTrackName = 'track_name';

  // Host
  String get host => _prefs.getString(_keyHost) ?? 'localhost';

  Future<void> setHost(String host) async {
    await _prefs.setString(_keyHost, host);
  }

  // Port
  String get port => _prefs.getString(_keyPort) ?? '8443';

  Future<void> setPort(String port) async {
    await _prefs.setString(_keyPort, port);
  }

  // URL (for WebTransport)
  String get url => _prefs.getString(_keyUrl) ?? 'https://localhost:4433/moq';

  Future<void> setUrl(String url) async {
    await _prefs.setString(_keyUrl, url);
  }

  // Insecure mode
  bool get insecureMode => _prefs.getBool(_keyInsecureMode) ?? false;

  Future<void> setInsecureMode(bool insecure) async {
    await _prefs.setBool(_keyInsecureMode, insecure);
  }

  // Namespace
  String get namespace => _prefs.getString(_keyNamespace) ?? 'demo';

  Future<void> setNamespace(String namespace) async {
    await _prefs.setString(_keyNamespace, namespace);
  }

  // Track name
  String get trackName => _prefs.getString(_keyTrackName) ?? 'video';

  Future<void> setTrackName(String trackName) async {
    await _prefs.setString(_keyTrackName, trackName);
  }
}
