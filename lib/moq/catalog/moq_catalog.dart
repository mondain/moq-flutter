import 'dart:convert';
import 'dart:typed_data';

/// MoQ Catalog per draft-ietf-moq-catalogformat-01
///
/// A catalog is a specialized MoQ track that describes all available tracks
/// in a namespace. It provides information necessary for subscribers to
/// select, subscribe and initialize tracks.
class MoQCatalog {
  /// Catalog version (always 1 per current spec)
  final int version;

  /// Streaming format type (registered in IANA registry)
  final int streamingFormat;

  /// Streaming format version string
  final String streamingFormatVersion;

  /// Whether delta updates are supported
  final bool supportsDeltaUpdates;

  /// Common fields inherited by all tracks
  final CatalogCommonFields? commonTrackFields;

  /// List of tracks in the catalog
  final List<CatalogTrack> tracks;

  /// Well-known catalog track name
  static const String catalogTrackName = '.catalog';

  MoQCatalog({
    this.version = 1,
    required this.streamingFormat,
    required this.streamingFormatVersion,
    this.supportsDeltaUpdates = false,
    this.commonTrackFields,
    required this.tracks,
  });

  /// Create a simple LOC catalog with audio/video tracks
  factory MoQCatalog.loc({
    required String namespace,
    List<CatalogTrack>? tracks,
    String formatVersion = '0.2',
  }) {
    return MoQCatalog(
      version: 1,
      streamingFormat: 1, // LOC format
      streamingFormatVersion: formatVersion,
      supportsDeltaUpdates: false,
      commonTrackFields: CatalogCommonFields(
        namespace: namespace,
        packaging: 'loc',
        renderGroup: 1,
      ),
      tracks: tracks ?? [],
    );
  }

  /// Create a simple CMAF catalog with audio/video tracks
  factory MoQCatalog.cmaf({
    required String namespace,
    List<CatalogTrack>? tracks,
    String formatVersion = '0.2',
  }) {
    return MoQCatalog(
      version: 1,
      streamingFormat: 1, // CMAF format
      streamingFormatVersion: formatVersion,
      supportsDeltaUpdates: false,
      commonTrackFields: CatalogCommonFields(
        namespace: namespace,
        packaging: 'cmaf',
        renderGroup: 1,
      ),
      tracks: tracks ?? [],
    );
  }

  /// Add a video track to the catalog
  void addVideoTrack({
    required String name,
    String? namespace,
    String? codec,
    int? width,
    int? height,
    int? framerate,
    int? bitrate,
    String? initData,
    String? initTrack,
    int? altGroup,
  }) {
    tracks.add(CatalogTrack(
      name: name,
      namespace: namespace,
      selectionParams: SelectionParams(
        codec: codec,
        width: width,
        height: height,
        framerate: framerate,
        bitrate: bitrate,
      ),
      initData: initData,
      initTrack: initTrack,
      altGroup: altGroup,
    ));
  }

  /// Add an audio track to the catalog
  void addAudioTrack({
    required String name,
    String? namespace,
    String? codec,
    int? samplerate,
    String? channelConfig,
    int? bitrate,
    String? initData,
    String? initTrack,
    int? altGroup,
  }) {
    tracks.add(CatalogTrack(
      name: name,
      namespace: namespace,
      selectionParams: SelectionParams(
        codec: codec,
        samplerate: samplerate,
        channelConfig: channelConfig,
        bitrate: bitrate,
      ),
      initData: initData,
      initTrack: initTrack,
      altGroup: altGroup,
    ));
  }

  /// Serialize catalog to JSON string
  String toJson() {
    final json = <String, dynamic>{
      'version': version,
      'streamingFormat': streamingFormat,
      'streamingFormatVersion': streamingFormatVersion,
    };

    if (supportsDeltaUpdates) {
      json['supportsDeltaUpdates'] = true;
    }

    if (commonTrackFields != null) {
      json['commonTrackFields'] = commonTrackFields!.toJson();
    }

    json['tracks'] = tracks.map((t) => t.toJson()).toList();

    return const JsonEncoder.withIndent('  ').convert(json);
  }

  /// Serialize catalog to bytes for MoQ transmission
  Uint8List toBytes() {
    return Uint8List.fromList(utf8.encode(toJson()));
  }

  /// Parse catalog from JSON string
  static MoQCatalog fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    return MoQCatalog(
      version: json['version'] as int? ?? 1,
      streamingFormat: json['streamingFormat'] as int,
      streamingFormatVersion: json['streamingFormatVersion'] as String,
      supportsDeltaUpdates: json['supportsDeltaUpdates'] as bool? ?? false,
      commonTrackFields: json['commonTrackFields'] != null
          ? CatalogCommonFields.fromJson(
              json['commonTrackFields'] as Map<String, dynamic>)
          : null,
      tracks: (json['tracks'] as List<dynamic>)
          .map((t) => CatalogTrack.fromJson(t as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Parse catalog from bytes
  static MoQCatalog fromBytes(Uint8List bytes) {
    return fromJson(utf8.decode(bytes));
  }
}

/// Common track fields inherited by all tracks
class CatalogCommonFields {
  final String? namespace;
  final String? packaging;
  final int? renderGroup;

  CatalogCommonFields({
    this.namespace,
    this.packaging,
    this.renderGroup,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (namespace != null) json['namespace'] = namespace;
    if (packaging != null) json['packaging'] = packaging;
    if (renderGroup != null) json['renderGroup'] = renderGroup;
    return json;
  }

  static CatalogCommonFields fromJson(Map<String, dynamic> json) {
    return CatalogCommonFields(
      namespace: json['namespace'] as String?,
      packaging: json['packaging'] as String?,
      renderGroup: json['renderGroup'] as int?,
    );
  }
}

/// Individual track in the catalog
class CatalogTrack {
  final String name;
  final String? namespace;
  final String? packaging;
  final String? label;
  final int? renderGroup;
  final int? altGroup;
  final String? initData;
  final String? initTrack;
  final SelectionParams? selectionParams;
  final List<String>? depends;
  final int? temporalId;
  final int? spatialId;

  CatalogTrack({
    required this.name,
    this.namespace,
    this.packaging,
    this.label,
    this.renderGroup,
    this.altGroup,
    this.initData,
    this.initTrack,
    this.selectionParams,
    this.depends,
    this.temporalId,
    this.spatialId,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'name': name};
    if (namespace != null) json['namespace'] = namespace;
    if (packaging != null) json['packaging'] = packaging;
    if (label != null) json['label'] = label;
    if (renderGroup != null) json['renderGroup'] = renderGroup;
    if (altGroup != null) json['altGroup'] = altGroup;
    if (initData != null) json['initData'] = initData;
    if (initTrack != null) json['initTrack'] = initTrack;
    if (selectionParams != null) json['selectionParams'] = selectionParams!.toJson();
    if (depends != null && depends!.isNotEmpty) json['depends'] = depends;
    if (temporalId != null) json['temporalId'] = temporalId;
    if (spatialId != null) json['spatialId'] = spatialId;
    return json;
  }

  static CatalogTrack fromJson(Map<String, dynamic> json) {
    return CatalogTrack(
      name: json['name'] as String,
      namespace: json['namespace'] as String?,
      packaging: json['packaging'] as String?,
      label: json['label'] as String?,
      renderGroup: json['renderGroup'] as int?,
      altGroup: json['altGroup'] as int?,
      initData: json['initData'] as String?,
      initTrack: json['initTrack'] as String?,
      selectionParams: json['selectionParams'] != null
          ? SelectionParams.fromJson(
              json['selectionParams'] as Map<String, dynamic>)
          : null,
      depends: (json['depends'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      temporalId: json['temporalId'] as int?,
      spatialId: json['spatialId'] as int?,
    );
  }
}

/// Track selection parameters
class SelectionParams {
  final String? codec;
  final String? mimeType;
  final int? framerate;
  final int? bitrate;
  final int? width;
  final int? height;
  final int? samplerate;
  final String? channelConfig;
  final int? displayWidth;
  final int? displayHeight;
  final String? lang;

  SelectionParams({
    this.codec,
    this.mimeType,
    this.framerate,
    this.bitrate,
    this.width,
    this.height,
    this.samplerate,
    this.channelConfig,
    this.displayWidth,
    this.displayHeight,
    this.lang,
  });

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (codec != null) json['codec'] = codec;
    if (mimeType != null) json['mimeType'] = mimeType;
    if (framerate != null) json['framerate'] = framerate;
    if (bitrate != null) json['bitrate'] = bitrate;
    if (width != null) json['width'] = width;
    if (height != null) json['height'] = height;
    if (samplerate != null) json['samplerate'] = samplerate;
    if (channelConfig != null) json['channelConfig'] = channelConfig;
    if (displayWidth != null) json['displayWidth'] = displayWidth;
    if (displayHeight != null) json['displayHeight'] = displayHeight;
    if (lang != null) json['lang'] = lang;
    return json;
  }

  static SelectionParams fromJson(Map<String, dynamic> json) {
    return SelectionParams(
      codec: json['codec'] as String?,
      mimeType: json['mimeType'] as String?,
      framerate: json['framerate'] as int?,
      bitrate: json['bitrate'] as int?,
      width: json['width'] as int?,
      height: json['height'] as int?,
      samplerate: json['samplerate'] as int?,
      channelConfig: json['channelConfig'] as String?,
      displayWidth: json['displayWidth'] as int?,
      displayHeight: json['displayHeight'] as int?,
      lang: json['lang'] as String?,
    );
  }
}
