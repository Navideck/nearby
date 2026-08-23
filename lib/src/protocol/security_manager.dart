import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Ephemeral key pair for Diffie-Hellman authenticated key exchange.
class SecurityKeyPair {
  final BigInt privateKey;
  final String publicKeyHex;

  const SecurityKeyPair({
    required this.privateKey,
    required this.publicKeyHex,
  });
}

/// Manages ephemeral key exchange, authenticated transcript calculation, and Short Authentication String (SAS) calculation.
class SecurityManager {
  static final Random _secureRandom = Random.secure();

  // RFC 3526 2048-bit MODP Group 14 Prime
  static final BigInt dhPrime = BigInt.parse(
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1'
    '29024E088A67CC74020BBEA63B139B22514A08798E3404DD'
    'EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245'
    'E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
    'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3D'
    'C2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F'
    '83655D23DCA3AD961C62F356208552BB9ED529077096966D'
    '670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B'
    'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9'
    'DE2BCBF6955817183995497CEA956AE515D2261898FA0510'
    '15728E5A8AACAA68FFFFFFFFFFFFFFFF',
    radix: 16,
  );

  static final BigInt dhGenerator = BigInt.from(2);

  /// Generates an ephemeral Diffie-Hellman key pair for the handshake session.
  static SecurityKeyPair generateKeyPair() {
    // Generate 256-bit random private exponent
    final bytes = List<int>.generate(32, (i) => _secureRandom.nextInt(256));
    bytes[0] |= 0x80; // Ensure high bit set
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final priv = BigInt.parse(hex, radix: 16);
    final pub = dhGenerator.modPow(priv, dhPrime);
    return SecurityKeyPair(privateKey: priv, publicKeyHex: pub.toRadixString(16));
  }

  /// Generates a cryptographically secure random token or public key string.
  static String generateHandshakeToken() {
    return generateKeyPair().publicKeyHex;
  }

  /// Computes the Diffie-Hellman shared secret from a private key and remote public key.
  static String computeSharedSecret({
    required BigInt privateKey,
    required String remotePublicKeyHex,
  }) {
    final remotePub = BigInt.parse(remotePublicKeyHex, radix: 16);
    if (remotePub <= BigInt.one || remotePub >= dhPrime - BigInt.one) {
      throw ArgumentError('Invalid remote public key');
    }
    final sharedSecret = remotePub.modPow(privateKey, dhPrime);
    return sharedSecret.toRadixString(16);
  }

  /// Computes a canonical authenticated transcript digest from the key exchange and metadata.
  static String computeTranscriptDigest({
    required String localPeerId,
    required String localToken,
    required String remotePeerId,
    required String remoteToken,
    String? sharedSecretHex,
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

    final secretComponent = sharedSecretHex ?? '';
    final String combined =
        '${sortedComponents.join('|')}|SECRET:$secretComponent|META:$metaStr';
    return sha256.convert(utf8.encode(combined)).toString();
  }

  /// Calculates a deterministic 4-digit or 6-digit Short Authentication String (PIN)
  /// derived from the authenticated handshake transcript digest.
  static String calculateSasPin({
    required String localPeerId,
    required String localToken,
    required String remotePeerId,
    required String remoteToken,
    String? sharedSecretHex,
    Map<String, String> metadata = const {},
    int pinDigits = 4,
  }) {
    if (pinDigits != 4 && pinDigits != 6) {
      throw ArgumentError('pinDigits must be either 4 or 6, but was $pinDigits');
    }

    final String transcriptDigest = computeTranscriptDigest(
      localPeerId: localPeerId,
      localToken: localToken,
      remotePeerId: remotePeerId,
      remoteToken: remoteToken,
      sharedSecretHex: sharedSecretHex,
      metadata: metadata,
    );

    final Uint8List bytes =
        Uint8List.fromList(sha256.convert(utf8.encode(transcriptDigest)).bytes);

    // Extract a 32-bit unsigned integer from the first 4 bytes of hash
    final ByteData byteData = ByteData.sublistView(bytes);
    final int value = byteData.getUint32(0, Endian.big);

    final int modulus = pow(10, pinDigits).toInt();
    final int pinInt = (value.abs()) % modulus;
    return pinInt.toString().padLeft(pinDigits, '0');
  }

  /// Derives an authenticated session key using HKDF-SHA256 from the shared secret and transcript digest.
  static Uint8List deriveSessionKey({
    required String sharedSecretHex,
    required String transcriptDigest,
    String contextInfo = 'navideck-nearby-session-key',
  }) {
    if (sharedSecretHex.isEmpty) {
      throw ArgumentError('sharedSecretHex must not be empty');
    }
    final ikm = utf8.encode(sharedSecretHex);
    final salt = utf8.encode(transcriptDigest);
    final info = utf8.encode(contextInfo);

    // HKDF-Extract: PRK = HMAC-SHA256(salt, IKM)
    final hmacExtract = Hmac(sha256, salt);
    final prk = hmacExtract.convert(ikm).bytes;

    // HKDF-Expand: OKM = HMAC-SHA256(PRK, info || 0x01)
    final hmacExpand = Hmac(sha256, prk);
    final okm = hmacExpand.convert([...info, 0x01]).bytes;

    return Uint8List.fromList(okm);
  }

  /// Computes a verification hash for a payload chunk or full byte sequence.
  static String computeSha256(List<int> data) {
    return sha256.convert(data).toString();
  }
}
