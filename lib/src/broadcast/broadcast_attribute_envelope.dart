import 'dart:convert';
import 'dart:typed_data';

/// Result of decoding a [BroadcastAttributeEnvelope]-framed datagram.
class DecodedBroadcastEnvelope {
  final Uint8List data;
  final Map<String, String> attributes;

  const DecodedBroadcastEnvelope({required this.data, required this.attributes});
}

/// Wraps opaque [data] together with small string key/value [attributes] into
/// a single binary envelope for transmission over network multicast.
///
/// Format: `[1 byte count][entry]*[remaining bytes: data]`, where each entry is
/// `[1 byte keyLen][key utf8][2 bytes valueLen (big endian)][value utf8]`.
///
/// This envelope is only ever used for the network transport - BLE
/// advertisement payloads are sent unwrapped so they stay within the legacy
/// 31-byte advertisement budget.
Uint8List encodeBroadcastEnvelope(
  Uint8List data, {
  Map<String, String>? attributes,
}) {
  if (attributes == null || attributes.isEmpty) {
    final builder = BytesBuilder(copy: false);
    builder.addByte(0);
    builder.add(data);
    return builder.toBytes();
  }
  if (attributes.length > 255) {
    throw ArgumentError.value(
      attributes.length,
      'attributes.length',
      'must be <= 255',
    );
  }

  final builder = BytesBuilder(copy: false);
  builder.addByte(attributes.length);
  attributes.forEach((key, value) {
    final keyBytes = utf8.encode(key);
    final valueBytes = utf8.encode(value);
    if (keyBytes.length > 255) {
      throw ArgumentError.value(key, 'attributes key', 'must be <= 255 bytes');
    }
    if (valueBytes.length > 65535) {
      throw ArgumentError.value(
        value,
        'attributes value',
        'must be <= 65535 bytes',
      );
    }
    builder.addByte(keyBytes.length);
    builder.add(keyBytes);
    builder.addByte((valueBytes.length >> 8) & 0xff);
    builder.addByte(valueBytes.length & 0xff);
    builder.add(valueBytes);
  });
  builder.add(data);
  return builder.toBytes();
}

/// Decodes a datagram produced by [encodeBroadcastEnvelope]. Returns `null` if
/// [raw] is malformed/truncated.
DecodedBroadcastEnvelope? decodeBroadcastEnvelope(Uint8List raw) {
  try {
    if (raw.isEmpty) return null;
    var offset = 0;
    final count = raw[offset];
    offset += 1;

    final attributes = <String, String>{};
    for (var i = 0; i < count; i++) {
      final keyLen = raw[offset];
      offset += 1;
      final key = utf8.decode(raw.sublist(offset, offset + keyLen));
      offset += keyLen;

      final valueLen = (raw[offset] << 8) | raw[offset + 1];
      offset += 2;
      final value = utf8.decode(raw.sublist(offset, offset + valueLen));
      offset += valueLen;

      attributes[key] = value;
    }

    final data = Uint8List.sublistView(raw, offset);
    return DecodedBroadcastEnvelope(data: data, attributes: attributes);
  } catch (_) {
    return null;
  }
}
