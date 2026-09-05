import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/src/broadcast/broadcast_attribute_envelope.dart';

void main() {
  group('broadcast attribute envelope', () {
    test('round-trips data with no attributes', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = encodeBroadcastEnvelope(data);
      final decoded = decodeBroadcastEnvelope(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.data, data);
      expect(decoded.attributes, isEmpty);
    });

    test('round-trips data with attributes', () {
      final data = Uint8List.fromList([9, 8, 7]);
      final attributes = {'controlPort': '9877', 'cslate_port': '54321'};
      final encoded = encodeBroadcastEnvelope(data, attributes: attributes);
      final decoded = decodeBroadcastEnvelope(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.data, data);
      expect(decoded.attributes, attributes);
    });

    test('round-trips empty data with attributes', () {
      final data = Uint8List(0);
      final attributes = {'k': 'v'};
      final encoded = encodeBroadcastEnvelope(data, attributes: attributes);
      final decoded = decodeBroadcastEnvelope(encoded);

      expect(decoded!.data, isEmpty);
      expect(decoded.attributes, attributes);
    });

    test('empty attribute map behaves like no attributes', () {
      final data = Uint8List.fromList([1, 2]);
      final encoded = encodeBroadcastEnvelope(data, attributes: const {});
      final decoded = decodeBroadcastEnvelope(encoded);

      expect(decoded!.data, data);
      expect(decoded.attributes, isEmpty);
    });

    test('supports unicode keys and values', () {
      final data = Uint8List.fromList([0]);
      final attributes = {'名前': 'Café ☕'};
      final encoded = encodeBroadcastEnvelope(data, attributes: attributes);
      final decoded = decodeBroadcastEnvelope(encoded);

      expect(decoded!.attributes, attributes);
    });

    test('throws when a key exceeds 255 bytes', () {
      final key = 'k' * 256;
      expect(
        () => encodeBroadcastEnvelope(Uint8List(0), attributes: {key: 'v'}),
        throwsArgumentError,
      );
    });

    test('throws when more than 255 attributes are provided', () {
      final attributes = {for (var i = 0; i < 256; i++) 'k$i': 'v'};
      expect(
        () => encodeBroadcastEnvelope(Uint8List(0), attributes: attributes),
        throwsArgumentError,
      );
    });

    test('decode returns null for empty input', () {
      expect(decodeBroadcastEnvelope(Uint8List(0)), isNull);
    });

    test('decode returns null for truncated/malformed input', () {
      // Claims 1 attribute but has no bytes for it.
      final malformed = Uint8List.fromList([1]);
      expect(decodeBroadcastEnvelope(malformed), isNull);
    });
  });
}
