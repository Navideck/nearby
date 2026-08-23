import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  group('SecurityManager', () {
    test('generateHandshakeToken generates non-empty distinct hex strings', () {
      final token1 = SecurityManager.generateHandshakeToken();
      final token2 = SecurityManager.generateHandshakeToken();

      expect(token1.length, equals(64)); // 32 bytes hex encoded
      expect(token2.length, equals(64));
      expect(token1, isNot(equals(token2)));
    });

    test('calculateSasPin produces symmetric identical PIN on both sides', () {
      const localId = 'peer_A_iPhone';
      const localToken = 'token_secret_11111111111111111111111111111111';
      const remoteId = 'peer_B_Pixel';
      const remoteToken = 'token_secret_22222222222222222222222222222222';

      // Side A computes PIN:
      final pinSideA = SecurityManager.calculateSasPin(
        localPeerId: localId,
        localToken: localToken,
        remotePeerId: remoteId,
        remoteToken: remoteToken,
        pinDigits: 4,
      );

      // Side B computes PIN with roles reversed:
      final pinSideB = SecurityManager.calculateSasPin(
        localPeerId: remoteId,
        localToken: remoteToken,
        remotePeerId: localId,
        remoteToken: localToken,
        pinDigits: 4,
      );

      expect(pinSideA.length, equals(4));
      expect(pinSideB.length, equals(4));
      expect(pinSideA, equals(pinSideB));
    });

    test('calculateSasPin respects custom digit count', () {
      final pin6 = SecurityManager.calculateSasPin(
        localPeerId: 'id1',
        localToken: 'tok1',
        remotePeerId: 'id2',
        remoteToken: 'tok2',
        pinDigits: 6,
      );

      expect(pin6.length, equals(6));
      expect(int.tryParse(pin6), isNotNull);
    });

    test('computeSha256 produces valid 64-character hex digest', () {
      final hash = SecurityManager.computeSha256([1, 2, 3, 4]);
      expect(hash.length, equals(64));
    });
  });
}
