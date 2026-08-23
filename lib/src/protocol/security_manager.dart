import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Manages authentication tokens, authenticated transcript exchange, and Short Authentication String (SAS) calculation.
class SecurityManager {
  static final Random _secureRandom = Random.secure();

  /// Generates a cryptographically secure random token (32 bytes as hex).
  static String generateHandshakeToken() {
    final values = List<int>.generate(32, (i) => _secureRandom.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Computes a canonical authenticated transcript digest from the handshake exchange.
  static String computeTranscriptDigest({
    required String localPeerId,
    required String localToken,
    required String remotePeerId,
    required String remoteToken,
    Map<String, String> metadata = const {},
  }) {
    // Sort peer identifiers and tokens lexicographically to guarantee symmetry
    final List<String> sortedComponents = [
      '$localPeerId:$localToken',
      '$remotePeerId:$remoteToken',
    ]..sort();

    final sortedMeta = metadata.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final metaStr = sortedMeta.map((e) => '${e.key}=${e.value}').join('&');

    final String combined = '${sortedComponents.join('|')}|META:$metaStr';
    return sha256.convert(utf8.encode(combined)).toString();
  }

  /// Calculates a deterministic 4-digit or 6-digit Short Authentication String (PIN)
  /// derived from the authenticated handshake transcript digest.
  ///
  /// This ensures that both sides compute identical visual PINs regardless of who
  /// initiated the connection.
  static String calculateSasPin({
    required String localPeerId,
    required String localToken,
    required String remotePeerId,
    required String remoteToken,
    Map<String, String> metadata = const {},
    int pinDigits = 4,
  }) {
    final String transcriptDigest = computeTranscriptDigest(
      localPeerId: localPeerId,
      localToken: localToken,
      remotePeerId: remotePeerId,
      remoteToken: remoteToken,
      metadata: metadata,
    );

    final Uint8List bytes = Uint8List.fromList(sha256.convert(utf8.encode(transcriptDigest)).bytes);

    // Extract a 32-bit integer from the first 4 bytes of hash
    final ByteData byteData = ByteData.sublistView(bytes);
    final int value = byteData.getUint32(0, Endian.big);

    final int modulus = pow(10, pinDigits).toInt();
    final int pinInt = (value.abs()) % modulus;
    return pinInt.toString().padLeft(pinDigits, '0');
  }

  /// Derives an authenticated session verification key from the transcript digest using HMAC-SHA256.
  static Uint8List deriveSessionKey({
    required String transcriptDigest,
    String contextInfo = 'navideck-nearby-session-key',
  }) {
    final hmac = Hmac(sha256, utf8.encode(contextInfo));
    final digest = hmac.convert(utf8.encode(transcriptDigest));
    return Uint8List.fromList(digest.bytes);
  }

  /// Computes a verification hash for a payload chunk or full byte sequence.
  static String computeSha256(List<int> data) {
    return sha256.convert(data).toString();
  }
}
