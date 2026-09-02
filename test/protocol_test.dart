import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  group('PacketFrame Serialization & Parsing', () {
    test('HandshakeInit frame encodes and decodes properly', () {
      final frame = PacketFrame.handshakeInit(
        peerId: 'peer_123',
        displayName: 'Alice iPhone',
        token: 'token_abc',
        metadata: {'version': '2.0', 'role': 'host'},
      );

      final bytes = frame.toBytes();
      expect(bytes.isNotEmpty, isTrue);

      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, equals(FrameType.handshakeInit));

      final json = jsonDecode(utf8.decode(parsed.body)) as Map<String, dynamic>;
      expect(json['peerId'], equals('peer_123'));
      expect(json['displayName'], equals('Alice iPhone'));
      expect(json['token'], equals('token_abc'));
      expect(json['metadata']['version'], equals('2.0'));
      expect(json['metadata']['role'], equals('host'));
      expect(json['authentication'], equals('default'));
    });

    test('Pre-shared-key handshake frames carry proofs, not secrets', () {
      final init = PacketFrame.handshakeInit(
        peerId: 'peer_123',
        displayName: 'Alice',
        token: 'public_key',
        usesPreSharedKey: true,
      );
      final initJson =
          jsonDecode(utf8.decode(init.body)) as Map<String, dynamic>;
      expect(initJson['authentication'], 'preSharedKey');
      expect(initJson.toString(), isNot(contains('shared secret')));

      final ack = PacketFrame.handshakeAck(
        peerId: 'peer_456',
        displayName: 'Bob',
        token: 'public_key',
        accepted: true,
        usesPreSharedKey: true,
        proof: 'proof_value',
      );
      final ackJson = jsonDecode(utf8.decode(ack.body)) as Map<String, dynamic>;
      expect(ackJson['authentication'], 'preSharedKey');
      expect(ackJson['proof'], 'proof_value');

      final confirm = PacketFrame.handshakeConfirm(proof: 'confirm_value');
      expect(confirm.type, FrameType.handshakeConfirm);
    });

    test('HandshakeAck frame with accepted=true', () {
      final frame = PacketFrame.handshakeAck(
        peerId: 'peer_456',
        displayName: 'Bob Android',
        token: 'token_xyz',
        accepted: true,
      );

      final bytes = frame.toBytes();
      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, equals(FrameType.handshakeAck));

      final json = jsonDecode(utf8.decode(parsed.body)) as Map<String, dynamic>;
      expect(json['peerId'], equals('peer_456'));
      expect(json['accepted'], isTrue);
    });

    test('HandshakeAck frame with accepted=false and reason', () {
      final frame = PacketFrame.handshakeAck(
        peerId: 'peer_456',
        displayName: 'Bob Android',
        token: 'token_xyz',
        accepted: false,
        reason: 'User declined request',
      );

      final bytes = frame.toBytes();
      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, equals(FrameType.handshakeAck));

      final json = jsonDecode(utf8.decode(parsed.body)) as Map<String, dynamic>;
      expect(json['accepted'], isFalse);
      expect(json['reason'], equals('User declined request'));
    });

    test('Heartbeat frame serialization', () {
      final frame = PacketFrame.heartbeat();
      final bytes = frame.toBytes();
      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, equals(FrameType.heartbeat));
      expect(parsed.body.length, equals(0));
    });

    test('PayloadChunk frame with binary body and sequence', () {
      final rawData = Uint8List.fromList([1, 2, 3, 4, 5, 42, 100, 255]);
      final frame = PacketFrame.payloadChunk(
        payloadId: 987654321,
        sequence: 4,
        chunkData: rawData,
      );

      final bytes = frame.toBytes();
      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, equals(FrameType.payloadChunk));
      expect(parsed.payloadId, equals(987654321));
      expect(parsed.sequence, equals(4));
      expect(parsed.body, equals(rawData));
    });

    test('PacketFrame rejection on corrupted CRC32 checksum', () {
      final frame = PacketFrame.heartbeat();
      final bytes = frame.toBytes();

      // Corrupt a byte in the body or header
      bytes[3] = 0xFF; // Change frame type illegally without updating CRC

      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNull);
    });

    test('PacketFrame rejection on invalid magic bytes', () {
      final frame = PacketFrame.heartbeat();
      final bytes = frame.toBytes();

      bytes[0] = 0x00; // Invalidate magic byte

      final parsed = PacketFrame.fromBytes(bytes);
      expect(parsed, isNull);
    });

    test('PacketFrame rejection on truncated byte array', () {
      final frame = PacketFrame.payloadHeader(
        payloadId: 123,
        payloadType: 'bytes',
        totalBytes: 500,
      );
      final bytes = frame.toBytes();
      final truncated = bytes.sublist(0, bytes.length - 5);

      final parsed = PacketFrame.fromBytes(truncated);
      expect(parsed, isNull);
    });

    test('PacketFrame encrypted serialization and authentication', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final frame = PacketFrame.payloadChunk(
        payloadId: 555,
        sequence: 2,
        chunkData: Uint8List.fromList([1, 2, 3, 4, 5]),
      );

      final authBytes = frame.toBytes(sessionKey: key);
      // AES-GCM adds a 12-byte nonce and 16-byte tag to the encrypted body.
      expect(authBytes.length, equals(20 + 12 + 5 + 16 + 4 + 32));
      expect(authBytes.sublist(20, 25), isNot(equals(frame.body)));

      final parsed = PacketFrame.fromBytes(authBytes, sessionKey: key);
      expect(parsed, isNotNull);
      expect(parsed!.authTag, isNotNull);
      expect(parsed.authTag!.length, equals(32));
      expect(parsed.verifyAuthTag(key), isTrue);
      expect(parsed.decrypt(key).body, equals(frame.body));

      final wrongKey = Uint8List.fromList(List.generate(32, (i) => i + 2));
      expect(PacketFrame.fromBytes(authBytes, sessionKey: wrongKey), isNull);
      expect(parsed.verifyAuthTag(wrongKey), isFalse);
    });

    test(
      'PacketFrame rejection on tampered payload in authenticated frame',
      () {
        final key = Uint8List.fromList(List.generate(32, (i) => i + 1));
        final frame = PacketFrame.payloadChunk(
          payloadId: 555,
          sequence: 2,
          chunkData: Uint8List.fromList([1, 2, 3, 4, 5]),
        );

        final authBytes = frame.toBytes(sessionKey: key);
        // Tamper with body byte and recompute CRC32 to bypass simple checksum
        authBytes[20] = 0xAA;
        final newCrc = Crc32.compute(authBytes.sublist(0, 25));
        ByteData.sublistView(authBytes).setUint32(25, newCrc, Endian.big);

        // CRC32 passes, but HMAC verification MUST fail and reject the packet
        final parsed = PacketFrame.fromBytes(authBytes, sessionKey: key);
        expect(parsed, isNull);
      },
    );
  });

  group('PacketFramer Stream Processing', () {
    test(
      'Frames stream correctly when chunks arrive in single packet',
      () async {
        final framer = PacketFramer();
        final frame1 = PacketFrame.heartbeat();
        final frame2 = PacketFrame.payloadChunk(
          payloadId: 100,
          sequence: 0,
          chunkData: Uint8List.fromList([10, 20, 30]),
        );

        final collected = <PacketFrame>[];
        final sub = framer.frames.listen(collected.add);

        framer.addBytes(frame1.toBytes());
        framer.addBytes(frame2.toBytes());

        await Future.delayed(const Duration(milliseconds: 20));

        expect(collected.length, equals(2));
        expect(collected[0].type, equals(FrameType.heartbeat));
        expect(collected[1].type, equals(FrameType.payloadChunk));
        expect(collected[1].payloadId, equals(100));

        await sub.cancel();
        await framer.close();
      },
    );

    test(
      'Frames stream correctly when packet is fragmented into tiny chunks',
      () async {
        final framer = PacketFramer();
        final frame = PacketFrame.handshakeInit(
          peerId: 'peer_frag',
          displayName: 'Fragmented Peer Device',
          token: 'frag_token_123',
        );

        final fullBytes = frame.toBytes();
        final collected = <PacketFrame>[];
        final sub = framer.frames.listen(collected.add);

        // Feed 3 bytes at a time
        for (int i = 0; i < fullBytes.length; i += 3) {
          final end = (i + 3 < fullBytes.length) ? i + 3 : fullBytes.length;
          framer.addBytes(fullBytes.sublist(i, end));
        }

        await Future.delayed(const Duration(milliseconds: 20));

        expect(collected.length, equals(1));
        expect(collected[0].type, equals(FrameType.handshakeInit));

        await sub.cancel();
        await framer.close();
      },
    );

    test(
      'Framer recovers from noise/garbage bytes before valid packet',
      () async {
        final framer = PacketFramer();
        final frame = PacketFrame.heartbeat();

        final noise = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE]);
        final valid = frame.toBytes();
        final combined = Uint8List.fromList([...noise, ...valid]);

        final collected = <PacketFrame>[];
        final sub = framer.frames.listen(collected.add);

        framer.addBytes(combined);

        await Future.delayed(const Duration(milliseconds: 20));

        expect(collected.length, equals(1));
        expect(collected[0].type, equals(FrameType.heartbeat));

        await sub.cancel();
        await framer.close();
      },
    );
  });

  group('CRC32 Algorithm', () {
    test('Calculates deterministic CRC for known ASCII strings', () {
      final crc1 = Crc32.compute(utf8.encode('123456789'));
      // Standard CRC-32 for "123456789" is 0xCBF43926 = 3421780262
      expect(crc1, equals(0xCBF43926));

      final crc2 = Crc32.compute(Uint8List(0));
      expect(crc2, equals(0));
    });
  });
}
