import 'dart:typed_data';
import 'package:fixnum/fixnum.dart';
import 'package:logger/logger.dart';
import 'moq_messages.dart';

/// Parser for MoQ data streams (unidirectional streams carrying objects)
///
/// Each data stream starts with a SUBGROUP_HEADER followed by zero or more
/// objects. The parser maintains state to correctly calculate Object IDs
/// from deltas as specified in draft-ietf-moq-transport-14 Section 10.4.2.
class MoQDataStreamParser {
  final Logger _logger;

  /// The parsed subgroup header (available after first chunk processed)
  SubgroupHeader? header;

  /// Buffer for incomplete data
  final List<int> _buffer = [];

  /// Current object ID (used for delta calculations)
  Int64 _currentObjectId = Int64(0);

  /// Whether the header has been parsed
  bool get hasHeader => header != null;

  /// Whether extensions are present (determined by header type)
  bool _extensionsPresent = false;

  /// Whether the stream contains end of group
  bool _containsEndOfGroup = false;

  MoQDataStreamParser({Logger? logger}) : _logger = logger ?? Logger();

  /// Parse a chunk of data from the stream
  ///
  /// Returns a list of parsed objects (may be empty if more data is needed)
  List<SubgroupObject> parseChunk(Uint8List data) {
    _buffer.addAll(data);
    final results = <SubgroupObject>[];

    try {
      // Parse header if not yet parsed
      if (!hasHeader) {
        final headerResult = _tryParseHeader();
        if (headerResult == null) {
          // Need more data for header
          return results;
        }
      }

      // Parse objects
      while (_buffer.isNotEmpty) {
        final obj = _tryParseObject();
        if (obj == null) {
          // Need more data for next object
          break;
        }
        results.add(obj);
      }
    } catch (e) {
      _logger.e('Error parsing data stream: $e');
    }

    return results;
  }

  /// Try to parse the subgroup header from the buffer
  SubgroupHeader? _tryParseHeader() {
    if (_buffer.isEmpty) return null;

    final data = Uint8List.fromList(_buffer);
    int offset = 0;

    try {
      // Read type (varint)
      final (type, typeLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += typeLen;

      // Validate type is a SUBGROUP_HEADER (0x10-0x1D)
      if (type < 0x10 || type > 0x1D) {
        _logger.w('Invalid subgroup header type: 0x${type.toRadixString(16)}');
        return null;
      }

      // Decode type flags per draft-14 Table 7
      _extensionsPresent = _hasExtensions(type);
      _containsEndOfGroup = _hasEndOfGroup(type);
      final hasSubgroupIdField = _hasSubgroupIdField(type);
      final subgroupIdIsFirstObjectId = _subgroupIdIsFirstObjectId(type);

      // Read Track Alias
      final (trackAlias, aliasLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += aliasLen;

      // Read Group ID
      final (groupId, groupLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += groupLen;

      // Read Subgroup ID (conditional based on type)
      Int64 subgroupId;
      if (hasSubgroupIdField) {
        final (sid, sidLen) = MoQWireFormat.decodeVarint64(data, offset);
        offset += sidLen;
        subgroupId = sid;
      } else if (subgroupIdIsFirstObjectId) {
        // Subgroup ID will be the first object ID - set to 0 for now
        // Will be updated when first object is parsed
        subgroupId = Int64(0);
      } else {
        // Subgroup ID is 0
        subgroupId = Int64(0);
      }

      // Read Publisher Priority (1 byte)
      if (offset >= data.length) return null;
      final publisherPriority = data[offset++];

      // Read extension headers if present
      final headers = <KeyValuePair>[];
      // Note: Extension headers in SUBGROUP_HEADER are not per the spec
      // The extensions flag applies to objects within the subgroup

      // Successfully parsed header
      header = SubgroupHeader(
        trackAlias: trackAlias,
        groupId: groupId,
        subgroupId: subgroupId,
        publisherPriority: publisherPriority,
        extensionHeaders: headers,
      );

      // Remove parsed bytes from buffer
      _buffer.removeRange(0, offset);

      _logger.d('Parsed SUBGROUP_HEADER: trackAlias=$trackAlias, '
          'groupId=$groupId, subgroupId=$subgroupId');

      return header;
    } catch (e) {
      // Not enough data, return null
      return null;
    }
  }

  /// Try to parse an object from the buffer
  SubgroupObject? _tryParseObject() {
    if (_buffer.isEmpty || !hasHeader) return null;

    final data = Uint8List.fromList(_buffer);
    int offset = 0;

    try {
      // Read Object ID Delta (varint)
      final (objectIdDelta, deltaLen) = MoQWireFormat.decodeVarint64(data, offset);
      offset += deltaLen;

      // Calculate actual Object ID
      // Per spec: Object ID = previous Object ID + delta + 1 (if not first)
      // For first object, Object ID = delta
      final Int64 objectId;
      if (_currentObjectId == Int64(0)) {
        objectId = objectIdDelta;
      } else {
        objectId = _currentObjectId + objectIdDelta + Int64(1);
      }
      _currentObjectId = objectId;

      // Read Extension Headers Length if extensions present
      final extensionHeaders = <KeyValuePair>[];
      if (_extensionsPresent) {
        final (extLen, extLenLen) = MoQWireFormat.decodeVarint(data, offset);
        offset += extLenLen;

        // Parse extension headers if length > 0
        if (extLen > 0) {
          final extEnd = offset + extLen;
          while (offset < extEnd) {
            final (headerType, typeLen) = MoQWireFormat.decodeVarint(data, offset);
            offset += typeLen;

            Uint8List? value;
            // Even types have varint value, odd types have length-prefixed buffer
            // Per moq-mi spec: "Even types indicate value coded by a single varint.
            // Odd types indicates value is byte buffer with prefixed varint to indicate length"
            if (headerType % 2 == 0) {
              // Even type: value is a single varint
              final (varintValue, varintLen) = MoQWireFormat.decodeVarint(data, offset);
              offset += varintLen;
              // Store varint as single-byte array for consistency
              value = Uint8List.fromList([varintValue & 0xFF]);
            } else {
              // Odd type: value is length-prefixed buffer
              final (valueLen, valueLenLen) = MoQWireFormat.decodeVarint(data, offset);
              offset += valueLenLen;

              if (valueLen > 0) {
                if (offset + valueLen > data.length) return null;
                value = data.sublist(offset, offset + valueLen);
                offset += valueLen;
              }
            }

            extensionHeaders.add(KeyValuePair(type: headerType, value: value));
          }
        }
      }

      // Read Object Payload Length
      final (payloadLen, payloadLenLen) = MoQWireFormat.decodeVarint(data, offset);
      offset += payloadLenLen;

      // Determine if this is a status object (zero-length payload)
      ObjectStatus status = ObjectStatus.normal;
      Uint8List? payload;

      if (payloadLen == 0) {
        // Zero-length payload - need to read status
        if (offset >= data.length) return null;
        final statusByte = data[offset++];
        status = ObjectStatus.fromValue(statusByte) ?? ObjectStatus.normal;
      } else {
        // Read payload
        if (offset + payloadLen > data.length) return null;
        payload = data.sublist(offset, offset + payloadLen);
        offset += payloadLen;
      }

      // Successfully parsed object
      final obj = SubgroupObject(
        objectId: objectId,
        publisherPriority: header!.publisherPriority,
        status: status,
        extensionHeaders: extensionHeaders,
        payload: payload,
      );

      // Remove parsed bytes from buffer
      _buffer.removeRange(0, offset);

      _logger.d('Parsed object: objectId=$objectId, '
          'payloadLen=${payload?.length ?? 0}, status=${status.name}');

      return obj;
    } catch (e) {
      // Not enough data, return null
      return null;
    }
  }

  /// Check if type indicates extensions are present
  bool _hasExtensions(int type) {
    // Types with extensions: 0x11, 0x13, 0x15, 0x19, 0x1B, 0x1D
    return (type & 0x01) == 1;
  }

  /// Check if type indicates end of group
  bool _hasEndOfGroup(int type) {
    // Types 0x18-0x1D contain end of group
    return type >= 0x18;
  }

  /// Check if type has explicit Subgroup ID field
  bool _hasSubgroupIdField(int type) {
    // Types 0x14, 0x15, 0x1C, 0x1D have explicit Subgroup ID
    return type == 0x14 || type == 0x15 || type == 0x1C || type == 0x1D;
  }

  /// Check if Subgroup ID is derived from first Object ID
  bool _subgroupIdIsFirstObjectId(int type) {
    // Types 0x12, 0x13, 0x1A, 0x1B use first Object ID as Subgroup ID
    return type == 0x12 || type == 0x13 || type == 0x1A || type == 0x1B;
  }

  /// Reset the parser state
  void reset() {
    header = null;
    _buffer.clear();
    _currentObjectId = Int64(0);
    _extensionsPresent = false;
    _containsEndOfGroup = false;
  }

  /// Get remaining buffered bytes
  int get bufferedBytes => _buffer.length;
}
