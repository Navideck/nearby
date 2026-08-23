import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Manages authentication tokens and Short Authentication String (SAS) calculation.
class SecurityManager {
  static final Random _secureRandom = Random.secure();

  /// Generates a cryptographically secure random token (32 bytes as hex).
  static String generateHandshakeToken() {
    final values = List<int>.generate(32, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Calculates a deterministic 4-digit or 6-digit Short Authentication String (PIN)
  /// given both peer handshake tokens and their respective IDs.
  ///
  /// This ensures that both sides compute identical visual PINs regardless of who
  /// initiated the connection.
  static String calculateSasPin({
    required String localPeerId,
    required String localToken,
    required String remotePeerId,
    required String remoteToken,
    int pinDigits = 4,
  }) {
    // Sort peer identifiers and tokens lexicographically to guarantee symmetry
    final List<String> sortedComponents = [
      '$localPeerId:$localToken',
      '$remotePeerId:$remoteToken',
    ]..sort();

    final String combined = sortedComponents.join('|');
    final Digest hash = sha256.convert(utf8.encode(combined));
    final Uint8List bytes = Uint8List.fromList(hash.bytes);

    // Extract a 32-bit integer from the first 4 bytes of hash
    final ByteData byteData = ByteData.sublistView(bytes);
    final int value = byteData.getUint32(0, Endian.big);

    final int modulus = pow(10, pinDigits).toInt();
    final int pinInt = (value.abs()) % modulus;
    return pinInt.toString().padLeft(pinDigits, '0');
  }

  /// Computes a verification hash for a payload chunk or full byte sequence.
  static String computeSha256(List<int> data) {
    return sha256.convert(data).toString();
  }
}
