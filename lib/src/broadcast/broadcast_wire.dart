import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'broadcast_attribute_envelope.dart';

/// Compact connectionless framing. IDs are fingerprints, not authentication.
/// A 32-bit collision is possible; callers must not use these IDs for trust.
class BroadcastWire {
  static const localNamePrefix = 'N2';
  static const maxBleDataLength = 10;
  final String channelId;
  final Uint8List _channel;

  BroadcastWire(this.channelId) : _channel = _fingerprint(channelId);

  static Uint8List _fingerprint(String value) => Uint8List.fromList(
    sha256.convert(utf8.encode(value)).bytes.take(4).toList(),
  );

  static String senderFingerprint(String senderId) =>
      _hex(_fingerprint(senderId));

  static String _hex(Iterable<int> value) =>
      value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Uint8List encode(Uint8List data, String senderId) =>
      Uint8List.fromList([..._channel, ..._fingerprint(senderId), ...data]);

  ({String senderId, Uint8List data})? decode(Uint8List bytes) {
    if (bytes.length < 8) return null;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _channel[i]) return null;
    }
    return (senderId: _hex(bytes.sublist(4, 8)), data: bytes.sublist(8));
  }

  String localName(Uint8List bytes) {
    if (bytes.length > 18) {
      throw ArgumentError(
        'BLE broadcasts support at most $maxBleDataLength data bytes',
      );
    }
    // 18 bytes = 24 base64 chars + 2 prefix chars. With AD header (2)
    // and flags (3), this fits legacy advertising's 31-byte budget.
    return '$localNamePrefix${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  Uint8List? decodeLocalName(String? name) {
    if (name == null || !name.startsWith(localNamePrefix) || name.length > 26) {
      return null;
    }
    try {
      return base64Url.decode(base64.normalize(name.substring(2)));
    } on FormatException {
      return null;
    }
  }

  Uint8List encodeNetwork(
    Uint8List data,
    String senderId,
    String? displayName,
    Map<String, String> attributes,
  ) {
    final bytes = encodeBroadcastEnvelope(
      encode(data, senderId),
      attributes: {
        ...attributes,
        'nearby.channel': channelId,
        'nearby.sender': senderId,
        'nearby.name': ?displayName,
      },
    );
    if (bytes.length > 65507) {
      throw ArgumentError('UDP payload exceeds 65507 bytes');
    }
    return bytes;
  }

  DecodedBroadcastEnvelope? decodeNetwork(Uint8List bytes) {
    final envelope = decodeBroadcastEnvelope(bytes);
    if (envelope == null ||
        envelope.attributes['nearby.channel'] != channelId) {
      return null;
    }
    final sender = envelope.attributes['nearby.sender'];
    final payload = decode(envelope.data);
    if (sender == null ||
        sender.isEmpty ||
        payload == null ||
        senderFingerprint(sender) != payload.senderId) {
      return null;
    }
    return envelope;
  }
}
