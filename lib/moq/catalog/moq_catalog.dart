import 'dart:convert';
import 'dart:typed_data';

/// MoQ media catalog used by MSF/CMSF successors to WARP/CARP.
///
/// The current implementation serializes the newer flattened track shape while
/// remaining tolerant of older catalogformat/WARP-style input.
class MoQCatalog {
  final int version;
  final String? format;
  final int generatedAt;
  final bool isComplete;
  final List<CatalogTrack> tracks;

  /// Well-known catalog track name in the newer drafts.
  static const String catalogTrackName = 'catalog';

  /// Legacy track name accepted on input for compatibility only.
  static const String legacyCatalogTrackName = '.catalog';

  MoQCatalog({
    this.version = 1,
    this.format,
    int? generatedAt,
    this.isComplete = false,
    required this.tracks,
  }) : generatedAt = generatedAt ?? DateTime.now().millisecondsSinceEpoch;

  factory MoQCatalog.loc({
    required String namespace,
    List<CatalogTrack>? tracks,
    bool isComplete = false,
  }) {
    final catalogTracks = tracks ?? <CatalogTrack>[];
    return MoQCatalog(
      format: 'loc',
      isComplete: isComplete,
      tracks: catalogTracks
          .map(
            (track) => track.copyWith(
              namespace: track.namespace ?? namespace,
              packaging: track.packaging ?? 'loc',
            ),
          )
          .toList(),
    );
  }

  factory MoQCatalog.cmaf({
    required String namespace,
    List<CatalogTrack>? tracks,
    bool isComplete = false,
  }) {
    final catalogTracks = tracks ?? <CatalogTrack>[];
    return MoQCatalog(
      format: 'cmsf',
      isComplete: isComplete,
      tracks: catalogTracks
          .map(
            (track) => track.copyWith(
              namespace: track.namespace ?? namespace,
              packaging: track.packaging ?? 'cmaf',
            ),
          )
          .toList(),
    );
  }

  String toJson() {
    final json = <String, dynamic>{
      'version': version,
      'generatedAt': generatedAt,
      'isComplete': isComplete,
    };
    if (format != null) json['format'] = format;
    json['tracks'] = tracks.map((t) => t.toJson()).toList();

    return const JsonEncoder.withIndent('  ').convert(json);
  }

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(toJson()));

  static MoQCatalog fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    final legacyCommonFields = json['commonTrackFields'] != null
        ? CatalogCommonFields.fromJson(
            json['commonTrackFields'] as Map<String, dynamic>,
          )
        : null;

    final tracks = (json['tracks'] as List<dynamic>? ?? const [])
        .map((t) => CatalogTrack.fromJson(t as Map<String, dynamic>))
        .map(
          (track) => track.copyWith(
            namespace: track.namespace ?? legacyCommonFields?.namespace,
            packaging: track.packaging ?? legacyCommonFields?.packaging,
            renderGroup: track.renderGroup ?? legacyCommonFields?.renderGroup,
          ),
        )
        .toList();

    return MoQCatalog(
      version: json['version'] as int? ?? 1,
      format: json['format'] as String?,
      generatedAt: json['generatedAt'] as int?,
      isComplete: json['isComplete'] as bool? ?? false,
      tracks: tracks,
    );
  }

  static MoQCatalog fromBytes(Uint8List bytes) {
    return fromJson(utf8.decode(bytes));
  }
}

/// Legacy common-track fields retained for backward-compatible parsing.
class CatalogCommonFields {
  final String? namespace;
  final String? packaging;
  final int? renderGroup;

  CatalogCommonFields({this.namespace, this.packaging, this.renderGroup});

  static CatalogCommonFields fromJson(Map<String, dynamic> json) {
    return CatalogCommonFields(
      namespace: json['namespace'] as String?,
      packaging: json['packaging'] as String?,
      renderGroup: json['renderGroup'] as int?,
    );
  }
}

class CatalogTrack {
  final String name;
  final String? namespace;
  final String? packaging;
  final String? label;
  final String? role;
  final String? parentName;
  final String? initData;
  final String? initTrack;
  final String? eventType;
  final int? renderGroup;
  final int? altGroup;
  final int? temporalId;
  final int? spatialId;
  final int? targetLatency;
  final int? timescale;
  final int? maxGroupSapStartingType;
  final int? maxObjectSapStartingType;
  final bool? isLive;
  final List<String>? depends;
  final SelectionParams? selectionParams;

  CatalogTrack({
    required this.name,
    this.namespace,
    this.packaging,
    this.label,
    this.role,
    this.parentName,
    this.initData,
    this.initTrack,
    this.eventType,
    this.renderGroup,
    this.altGroup,
    this.temporalId,
    this.spatialId,
    this.targetLatency,
    this.timescale,
    this.maxGroupSapStartingType,
    this.maxObjectSapStartingType,
    this.isLive,
    this.depends,
    this.selectionParams,
  });

  CatalogTrack copyWith({
    String? name,
    Object? namespace = _unset,
    Object? packaging = _unset,
    Object? label = _unset,
    Object? role = _unset,
    Object? parentName = _unset,
    Object? initData = _unset,
    Object? initTrack = _unset,
    Object? eventType = _unset,
    Object? renderGroup = _unset,
    Object? altGroup = _unset,
    Object? temporalId = _unset,
    Object? spatialId = _unset,
    Object? targetLatency = _unset,
    Object? timescale = _unset,
    Object? maxGroupSapStartingType = _unset,
    Object? maxObjectSapStartingType = _unset,
    Object? isLive = _unset,
    Object? depends = _unset,
    Object? selectionParams = _unset,
  }) {
    return CatalogTrack(
      name: name ?? this.name,
      namespace: namespace == _unset ? this.namespace : namespace as String?,
      packaging: packaging == _unset ? this.packaging : packaging as String?,
      label: label == _unset ? this.label : label as String?,
      role: role == _unset ? this.role : role as String?,
      parentName: parentName == _unset
          ? this.parentName
          : parentName as String?,
      initData: initData == _unset ? this.initData : initData as String?,
      initTrack: initTrack == _unset ? this.initTrack : initTrack as String?,
      eventType: eventType == _unset ? this.eventType : eventType as String?,
      renderGroup: renderGroup == _unset
          ? this.renderGroup
          : renderGroup as int?,
      altGroup: altGroup == _unset ? this.altGroup : altGroup as int?,
      temporalId: temporalId == _unset ? this.temporalId : temporalId as int?,
      spatialId: spatialId == _unset ? this.spatialId : spatialId as int?,
      targetLatency: targetLatency == _unset
          ? this.targetLatency
          : targetLatency as int?,
      timescale: timescale == _unset ? this.timescale : timescale as int?,
      maxGroupSapStartingType: maxGroupSapStartingType == _unset
          ? this.maxGroupSapStartingType
          : maxGroupSapStartingType as int?,
      maxObjectSapStartingType: maxObjectSapStartingType == _unset
          ? this.maxObjectSapStartingType
          : maxObjectSapStartingType as int?,
      isLive: isLive == _unset ? this.isLive : isLive as bool?,
      depends: depends == _unset ? this.depends : depends as List<String>?,
      selectionParams: selectionParams == _unset
          ? this.selectionParams
          : selectionParams as SelectionParams?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'name': name};
    if (namespace != null) json['namespace'] = namespace;
    if (packaging != null) json['packaging'] = packaging;
    if (label != null) json['label'] = label;
    if (role != null) json['role'] = role;
    if (parentName != null) json['parentName'] = parentName;
    if (renderGroup != null) json['renderGroup'] = renderGroup;
    if (altGroup != null) json['altGroup'] = altGroup;
    if (initData != null) json['initData'] = initData;
    if (initTrack != null) json['initTrack'] = initTrack;
    if (eventType != null) json['eventType'] = eventType;
    if (temporalId != null) json['temporalId'] = temporalId;
    if (spatialId != null) json['spatialId'] = spatialId;
    if (targetLatency != null) json['targetLatency'] = targetLatency;
    if (timescale != null) json['timescale'] = timescale;
    if (maxGroupSapStartingType != null) {
      json['maxGroupSapStartingType'] = maxGroupSapStartingType;
    }
    if (maxObjectSapStartingType != null) {
      json['maxObjectSapStartingType'] = maxObjectSapStartingType;
    }
    if (isLive != null) json['isLive'] = isLive;
    if (depends != null && depends!.isNotEmpty) json['depends'] = depends;
    if (selectionParams != null) {
      json.addAll(selectionParams!.toJson());
    }
    return json;
  }

  static CatalogTrack fromJson(Map<String, dynamic> json) {
    final legacySelection = json['selectionParams'] != null
        ? SelectionParams.fromJson(
            json['selectionParams'] as Map<String, dynamic>,
          )
        : null;
    final flatSelection = SelectionParams.fromJson(json);
    final selection = flatSelection.isEmpty ? legacySelection : flatSelection;

    return CatalogTrack(
      name: json['name'] as String,
      namespace: json['namespace'] as String?,
      packaging: json['packaging'] as String?,
      label: json['label'] as String?,
      role: json['role'] as String?,
      parentName: json['parentName'] as String?,
      initData: json['initData'] as String?,
      initTrack: json['initTrack'] as String?,
      eventType: json['eventType'] as String?,
      renderGroup: json['renderGroup'] as int?,
      altGroup: json['altGroup'] as int?,
      temporalId: json['temporalId'] as int?,
      spatialId: json['spatialId'] as int?,
      targetLatency: json['targetLatency'] as int?,
      timescale: json['timescale'] as int?,
      maxGroupSapStartingType: json['maxGroupSapStartingType'] as int?,
      maxObjectSapStartingType: json['maxObjectSapStartingType'] as int?,
      isLive: json['isLive'] as bool?,
      depends: (json['depends'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      selectionParams: selection,
    );
  }
}

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

  bool get isEmpty =>
      codec == null &&
      mimeType == null &&
      framerate == null &&
      bitrate == null &&
      width == null &&
      height == null &&
      samplerate == null &&
      channelConfig == null &&
      displayWidth == null &&
      displayHeight == null &&
      lang == null;

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

const Object _unset = Object();
