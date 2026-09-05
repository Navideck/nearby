import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  group('SecurityManager', () {
    test('generateKeyPair generates valid DH keys and shared secrets', () {
      final aliceKeys = SecurityManager.generateKeyPair();
      final bobKeys = SecurityManager.generateKeyPair();

      expect(aliceKeys.publicKeyHex.isNotEmpty, isTrue);
      expect(bobKeys.publicKeyHex.isNotEmpty, isTrue);
      expect(aliceKeys.publicKeyHex, isNot(equals(bobKeys.publicKeyHex)));

      // Compute shared secrets on both sides
      final aliceSecret = SecurityManager.computeSharedSecret(
        privateKey: aliceKeys.privateKey,
        remotePublicKeyHex: bobKeys.publicKeyHex,
      );
      final bobSecret = SecurityManager.computeSharedSecret(
        privateKey: bobKeys.privateKey,
        remotePublicKeyHex: aliceKeys.publicKeyHex,
      );

      expect(aliceSecret, equals(bobSecret));
      expect(aliceSecret.isNotEmpty, isTrue);
    });

    test('calculateSasPin produces symmetric identical PIN on both sides with DH shared secret', () {
      final aliceKeys = SecurityManager.generateKeyPair();
      final bobKeys = SecurityManager.generateKeyPair();

      final aliceSecret = SecurityManager.computeSharedSecret(
        privateKey: aliceKeys.privateKey,
        remotePublicKeyHex: bobKeys.publicKeyHex,
      );
      final bobSecret = SecurityManager.computeSharedSecret(
        privateKey: bobKeys.privateKey,
        remotePublicKeyHex: aliceKeys.publicKeyHex,
      );

      const aliceId = 'peer_alice_device';
      const bobId = 'peer_bob_device';

      // Side A computes PIN:
      final pinSideA = SecurityManager.calculateSasPin(
        localPeerId: aliceId,
        localToken: aliceKeys.publicKeyHex,
        remotePeerId: bobId,
        remoteToken: bobKeys.publicKeyHex,
        sharedSecretHex: aliceSecret,
        pinDigits: 4,
      );

      // Side B computes PIN with roles reversed:
      final pinSideB = SecurityManager.calculateSasPin(
        localPeerId: bobId,
        localToken: bobKeys.publicKeyHex,
        remotePeerId: aliceId,
        remoteToken: aliceKeys.publicKeyHex,
        sharedSecretHex: bobSecret,
        pinDigits: 4,
      );

      expect(pinSideA.length, equals(4));
      expect(pinSideB.length, equals(4));
      expect(pinSideA, equals(pinSideB));
    });

    test(
      'calculateSasPin respects 4 and 6 digit counts and rejects others',
      () {
        final pin4 = SecurityManager.calculateSasPin(
          localPeerId: 'id1',
          localToken: 'tok1',
          remotePeerId: 'id2',
          remoteToken: 'tok2',
          pinDigits: 4,
        );
        expect(pin4.length, equals(4));

        final pin6 = SecurityManager.calculateSasPin(
          localPeerId: 'id1',
          localToken: 'tok1',
          remotePeerId: 'id2',
          remoteToken: 'tok2',
          pinDigits: 6,
        );
        expect(pin6.length, equals(6));

        expect(
          () => SecurityManager.calculateSasPin(
            localPeerId: 'id1',
            localToken: 'tok1',
            remotePeerId: 'id2',
            remoteToken: 'tok2',
            pinDigits: 0,
          ),
          throwsArgumentError,
        );

        expect(
          () => SecurityManager.calculateSasPin(
            localPeerId: 'id1',
            localToken: 'tok1',
            remotePeerId: 'id2',
            remoteToken: 'tok2',
            pinDigits: 8,
          ),
          throwsArgumentError,
        );
      },
    );

    test('deriveSessionKey produces 32-byte authenticated session key from DH shared secret', () {
      final aliceKeys = SecurityManager.generateKeyPair();
      final bobKeys = SecurityManager.generateKeyPair();
      final secret = SecurityManager.computeSharedSecret(
        privateKey: aliceKeys.privateKey,
        remotePublicKeyHex: bobKeys.publicKeyHex,
      );

      final digest = SecurityManager.computeTranscriptDigest(
        localPeerId: 'p1',
        localToken: aliceKeys.publicKeyHex,
        remotePeerId: 'p2',
        remoteToken: bobKeys.publicKeyHex,
      );
      final key = SecurityManager.deriveSessionKey(
        sharedSecretHex: secret,
        transcriptDigest: digest,
      );
      expect(key.length, equals(32));

      expect(
        () => SecurityManager.deriveSessionKey(
          sharedSecretHex: '',
          transcriptDigest: digest,
        ),
        throwsArgumentError,
      );
    });

    test('computeSha256 produces valid 64-character hex digest', () {
      final hash = SecurityManager.computeSha256([1, 2, 3, 4]);
      expect(hash.length, equals(64));
    });

    test('computeHmac and verifyHmac correctly authenticate messages', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      final message = utf8.encode('Sensitive control frame');
      final hmac = SecurityManager.computeHmac(key, message);
      expect(hmac.length, equals(32));

      expect(SecurityManager.verifyHmac(key, message, hmac), isTrue);

      final tampered = utf8.encode('Tampered control frame');
      expect(SecurityManager.verifyHmac(key, tampered, hmac), isFalse);

      final corruptedHmac = Uint8List.fromList(hmac);
      corruptedHmac[0] ^= 0xFF;
      expect(SecurityManager.verifyHmac(key, message, corruptedHmac), isFalse);
    });
  });
}
