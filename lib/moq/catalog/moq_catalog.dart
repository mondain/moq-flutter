import 'dart:convert';
import 'dart:typed_data';

/// MoQ media catalog per draft-ietf-moq-msf-00 / draft-ietf-moq-cmsf-00.
///
/// MSF supersedes the older WARP, CARP, and catalogformat drafts.
/// CMSF extends MSF with CMAF packaging (`packaging: "cmaf"`) and
/// `initData` (Base64 init segment).
///
/// Required root fields: `version`, `tracks`.
/// Track-level `packaging` is required ("loc", "cmaf", "mediatimeline",
/// "eventtimeline").
class MoQCatalog {
  final int version;
  final int? generatedAt;
  final bool isComplete;
  final bool deltaUpdate;
  final List<CatalogTrack> tracks;
  final List<CatalogTrack>? addTracks;
  final List<String>? removeTracks;
  final List<CatalogCloneTrack>? cloneTracks;

  /// Well-known catalog track name per MSF Section 5.1.
  static const String catalogTrackName = 'catalog';

  /// Legacy track name accepted on input for compatibility only.
  static const String legacyCatalogTrackName = '.catalog';

  MoQCatalog({
    this.version = 1,
    this.generatedAt,
    this.isComplete = false,
    this.deltaUpdate = false,
    required this.tracks,
    this.addTracks,
    this.removeTracks,
    this.cloneTracks,
  });

  factory MoQCatalog.loc({
    required String namespace,
    List<CatalogTrack>? tracks,
    bool isComplete = false,
  }) {
    final catalogTracks = tracks ?? <CatalogTrack>[];
    return MoQCatalog(
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
    if (deltaUpdate) {
      return _toDeltaJson();
    }

    final json = <String, dynamic>{
      'version': version,
    };
    if (generatedAt != null) json['generatedAt'] = generatedAt;
    if (isComplete) json['isComplete'] = true;
    json['tracks'] = tracks.map((t) => t.toJson()).toList();

    return const JsonEncoder.withIndent('  ').convert(json);
  }

  String _toDeltaJson() {
    final json = <String, dynamic>{
      'deltaUpdate': true,
    };
    if (generatedAt != null) json['generatedAt'] = generatedAt;
    if (addTracks != null && addTracks!.isNotEmpty) {
      json['addTracks'] = addTracks!.map((t) => t.toJson()).toList();
    }
    if (removeTracks != null && removeTracks!.isNotEmpty) {
      json['removeTracks'] = removeTracks;
    }
    if (cloneTracks != null && cloneTracks!.isNotEmpty) {
      json['cloneTracks'] = cloneTracks!.map((t) => t.toJson()).toList();
    }
    return const JsonEncoder.withIndent('  ').convert(json);
  }

  Uint8List toBytes() => Uint8List.fromList(utf8.encode(toJson()));

  static MoQCatalog fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    // Backward compat: inherit from legacy commonTrackFields if present
    final legacyCommonFields = json['commonTrackFields'] != null
        ? _LegacyCommonFields.fromJson(
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

    final addTracks = (json['addTracks'] as List<dynamic>?)
        ?.map((t) => CatalogTrack.fromJson(t as Map<String, dynamic>))
        .toList();

    final removeTracks = (json['removeTracks'] as List<dynamic>?)
        ?.map((e) => e as String)
        .toList();

    final cloneTracks = (json['cloneTracks'] as List<dynamic>?)
        ?.map((t) => CatalogCloneTrack.fromJson(t as Map<String, dynamic>))
        .toList();

    return MoQCatalog(
      version: json['version'] is int
          ? json['version'] as int
          : int.tryParse(json['version']?.toString() ?? '') ?? 1,
      generatedAt: json['generatedAt'] as int?,
      isComplete: json['isComplete'] as bool? ?? false,
      deltaUpdate: json['deltaUpdate'] as bool? ?? false,
      tracks: tracks,
      addTracks: addTracks,
      removeTracks: removeTracks,
      cloneTracks: cloneTracks,
    );
  }

  static MoQCatalog fromBytes(Uint8List bytes) {
    return fromJson(utf8.decode(bytes));
  }
}

/// Legacy commonTrackFields retained for backward-compatible parsing of
/// older catalogformat-01/WARP-style catalogs.
class _LegacyCommonFields {
  final String? namespace;
  final String? packaging;
  final int? renderGroup;

  _LegacyCommonFields({this.namespace, this.packaging, this.renderGroup});

  static _LegacyCommonFields fromJson(Map<String, dynamic> json) {
    return _LegacyCommonFields(
      namespace: json['namespace'] as String?,
      packaging: json['packaging'] as String?,
      renderGroup: json['renderGroup'] as int?,
    );
  }
}

/// Clone track entry for delta update catalogs.
class CatalogCloneTrack {
  final String parentName;
  final String name;
  final Map<String, dynamic> overrides;

  CatalogCloneTrack({
    required this.parentName,
    required this.name,
    this.overrides = const {},
  });

  Map<String, dynamic> toJson() {
    return {
      'parentName': parentName,
      'name': name,
      ...overrides,
    };
  }

  static CatalogCloneTrack fromJson(Map<String, dynamic> json) {
    final parentName = json['parentName'] as String;
    final name = json['name'] as String;
    final overrides = Map<String, dynamic>.from(json)
      ..remove('parentName')
      ..remove('name');
    return CatalogCloneTrack(
      parentName: parentName,
      name: name,
      overrides: overrides,
    );
  }
}

/// Catalog track per MSF Section 5.1.
///
/// Required fields: `name`, `packaging`.
/// Selection params are flattened directly at track level (no nested object).
class CatalogTrack {
  // Required
  final String name;
  final String? packaging; // "loc", "cmaf", "mediatimeline", "eventtimeline"

  // Namespace / organization
  final String? namespace;
  final String? label;
  final String? role; // "video", "audio", "caption", "subtitle", etc.
  final int? renderGroup;
  final int? altGroup;
  final List<String>? depends;

  // Media properties
  final bool? isLive;
  final int? targetLatency;
  final int? trackDuration; // VOD duration in ms
  final String? initData; // Base64 init segment (CMSF)
  final String? initTrack;
  final int? temporalId;
  final int? spatialId;

  // CMSF-specific
  final int? maxGrpSapStartingType;
  final int? maxObjSapStartingType;

  // Event timeline
  final String? eventType;

  // Selection params (flattened at track level per MSF)
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

  CatalogTrack({
    required this.name,
    this.packaging,
    this.namespace,
    this.label,
    this.role,
    this.renderGroup,
    this.altGroup,
    this.depends,
    this.isLive,
    this.targetLatency,
    this.trackDuration,
    this.initData,
    this.initTrack,
    this.temporalId,
    this.spatialId,
    this.maxGrpSapStartingType,
    this.maxObjSapStartingType,
    this.eventType,
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

  CatalogTrack copyWith({
    String? name,
    Object? packaging = _unset,
    Object? namespace = _unset,
    Object? label = _unset,
    Object? role = _unset,
    Object? renderGroup = _unset,
    Object? altGroup = _unset,
    Object? depends = _unset,
    Object? isLive = _unset,
    Object? targetLatency = _unset,
    Object? trackDuration = _unset,
    Object? initData = _unset,
    Object? initTrack = _unset,
    Object? temporalId = _unset,
    Object? spatialId = _unset,
    Object? maxGrpSapStartingType = _unset,
    Object? maxObjSapStartingType = _unset,
    Object? eventType = _unset,
    Object? codec = _unset,
    Object? mimeType = _unset,
    Object? framerate = _unset,
    Object? bitrate = _unset,
    Object? width = _unset,
    Object? height = _unset,
    Object? samplerate = _unset,
    Object? channelConfig = _unset,
    Object? displayWidth = _unset,
    Object? displayHeight = _unset,
    Object? lang = _unset,
  }) {
    return CatalogTrack(
      name: name ?? this.name,
      packaging: packaging == _unset ? this.packaging : packaging as String?,
      namespace: namespace == _unset ? this.namespace : namespace as String?,
      label: label == _unset ? this.label : label as String?,
      role: role == _unset ? this.role : role as String?,
      renderGroup: renderGroup == _unset ? this.renderGroup : renderGroup as int?,
      altGroup: altGroup == _unset ? this.altGroup : altGroup as int?,
      depends: depends == _unset ? this.depends : depends as List<String>?,
      isLive: isLive == _unset ? this.isLive : isLive as bool?,
      targetLatency: targetLatency == _unset ? this.targetLatency : targetLatency as int?,
      trackDuration: trackDuration == _unset ? this.trackDuration : trackDuration as int?,
      initData: initData == _unset ? this.initData : initData as String?,
      initTrack: initTrack == _unset ? this.initTrack : initTrack as String?,
      temporalId: temporalId == _unset ? this.temporalId : temporalId as int?,
      spatialId: spatialId == _unset ? this.spatialId : spatialId as int?,
      maxGrpSapStartingType: maxGrpSapStartingType == _unset ? this.maxGrpSapStartingType : maxGrpSapStartingType as int?,
      maxObjSapStartingType: maxObjSapStartingType == _unset ? this.maxObjSapStartingType : maxObjSapStartingType as int?,
      eventType: eventType == _unset ? this.eventType : eventType as String?,
      codec: codec == _unset ? this.codec : codec as String?,
      mimeType: mimeType == _unset ? this.mimeType : mimeType as String?,
      framerate: framerate == _unset ? this.framerate : framerate as int?,
      bitrate: bitrate == _unset ? this.bitrate : bitrate as int?,
      width: width == _unset ? this.width : width as int?,
      height: height == _unset ? this.height : height as int?,
      samplerate: samplerate == _unset ? this.samplerate : samplerate as int?,
      channelConfig: channelConfig == _unset ? this.channelConfig : channelConfig as String?,
      displayWidth: displayWidth == _unset ? this.displayWidth : displayWidth as int?,
      displayHeight: displayHeight == _unset ? this.displayHeight : displayHeight as int?,
      lang: lang == _unset ? this.lang : lang as String?,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'name': name};
    if (namespace != null) json['namespace'] = namespace;
    if (packaging != null) json['packaging'] = packaging;
    if (isLive != null) json['isLive'] = isLive;
    if (targetLatency != null) json['targetLatency'] = targetLatency;
    if (trackDuration != null) json['trackDuration'] = trackDuration;
    if (role != null) json['role'] = role;
    if (label != null) json['label'] = label;
    if (renderGroup != null) json['renderGroup'] = renderGroup;
    if (altGroup != null) json['altGroup'] = altGroup;
    if (initData != null) json['initData'] = initData;
    if (initTrack != null) json['initTrack'] = initTrack;
    if (eventType != null) json['eventType'] = eventType;
    if (temporalId != null) json['temporalId'] = temporalId;
    if (spatialId != null) json['spatialId'] = spatialId;
    if (maxGrpSapStartingType != null) {
      json['maxGrpSapStartingType'] = maxGrpSapStartingType;
    }
    if (maxObjSapStartingType != null) {
      json['maxObjSapStartingType'] = maxObjSapStartingType;
    }
    if (depends != null && depends!.isNotEmpty) json['depends'] = depends;
    // Selection params flattened at track level per MSF
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

  static CatalogTrack fromJson(Map<String, dynamic> json) {
    // Accept both flattened (MSF) and nested selectionParams (legacy)
    String? codec = json['codec'] as String?;
    String? mimeType = json['mimeType'] as String?;
    int? framerate = json['framerate'] as int?;
    int? bitrate = json['bitrate'] as int?;
    int? width = json['width'] as int?;
    int? height = json['height'] as int?;
    int? samplerate = json['samplerate'] as int?;
    String? channelConfig = json['channelConfig'] as String?;
    int? displayWidth = json['displayWidth'] as int?;
    int? displayHeight = json['displayHeight'] as int?;
    String? lang = json['lang'] as String?;

    // Legacy nested selectionParams fallback
    if (codec == null && json['selectionParams'] != null) {
      final sp = json['selectionParams'] as Map<String, dynamic>;
      codec ??= sp['codec'] as String?;
      mimeType ??= sp['mimeType'] as String?;
      framerate ??= sp['framerate'] as int?;
      bitrate ??= sp['bitrate'] as int?;
      width ??= sp['width'] as int?;
      height ??= sp['height'] as int?;
      samplerate ??= sp['samplerate'] as int?;
      channelConfig ??= sp['channelConfig'] as String?;
      displayWidth ??= sp['displayWidth'] as int?;
      displayHeight ??= sp['displayHeight'] as int?;
      lang ??= sp['lang'] as String?;
    }

    return CatalogTrack(
      name: json['name'] as String,
      packaging: json['packaging'] as String?,
      namespace: json['namespace'] as String?,
      label: json['label'] as String?,
      role: json['role'] as String?,
      renderGroup: json['renderGroup'] as int?,
      altGroup: json['altGroup'] as int?,
      depends: (json['depends'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      isLive: json['isLive'] as bool?,
      targetLatency: json['targetLatency'] as int?,
      trackDuration: json['trackDuration'] as int?,
      initData: json['initData'] as String?,
      initTrack: json['initTrack'] as String?,
      temporalId: json['temporalId'] as int?,
      spatialId: json['spatialId'] as int?,
      maxGrpSapStartingType: json['maxGrpSapStartingType'] as int?,
      maxObjSapStartingType: json['maxObjSapStartingType'] as int?,
      eventType: json['eventType'] as String?,
      codec: codec,
      mimeType: mimeType,
      framerate: framerate,
      bitrate: bitrate,
      width: width,
      height: height,
      samplerate: samplerate,
      channelConfig: channelConfig,
      displayWidth: displayWidth,
      displayHeight: displayHeight,
      lang: lang,
    );
  }
}

const Object _unset = Object();
