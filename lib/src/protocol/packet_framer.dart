import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'security_manager.dart';

/// Magic bytes identifying the Nearby protocol frame ('N', 'B').
const int kMagicByte0 = 0x4E;
const int kMagicByte1 = 0x42;
const int kProtocolVersion = 1;
const int kHeaderLength = 20; // 2 (magic) + 1 (version) + 1 (type) + 8 (payloadId) + 4 (sequence) + 4 (length)
const int kMaxFrameBodyLength = 16 * 1024 * 1024; // 16 MB max frame body
const int kMaxFramerBufferLength = 32 * 1024 * 1024; // 32 MB max buffer

/// Frame types supported by the protocol.
enum FrameType {
  handshakeInit(0x01),
  handshakeAck(0x02),
  handshakeReject(0x03),
  heartbeat(0x04),
  disconnect(0x05),
  payloadHeader(0x10),
  payloadChunk(0x11),
  payloadAck(0x12),
  payloadCancel(0x13);

  final int value;
  const FrameType(this.value);

  static FrameType? fromValue(int value) {
    for (final type in FrameType.values) {
      if (type.value == value) return type;
    }
    return null;
  }
}

/// A structured packet frame transferred over the wire.
class PacketFrame {
  final FrameType type;
  final int payloadId;
  final int sequence;
  final Uint8List body;
  final Uint8List? authTag;

  const PacketFrame({
    required this.type,
    this.payloadId = 0,
    this.sequence = 0,
    required this.body,
    this.authTag,
  });

  /// Encodes the header, body, and CRC32 into a byte buffer.
  Uint8List _rawHeaderAndBody({required bool authenticated}) {
    final int bodyLength = body.length;
    final int totalLength = kHeaderLength + bodyLength + 4;
    final Uint8List buffer = Uint8List(totalLength);
    final ByteData byteData = ByteData.sublistView(buffer);

    // Magic & Version (set 0x80 bit if authenticated)
    buffer[0] = kMagicByte0;
    buffer[1] = kMagicByte1;
    buffer[2] = authenticated ? (kProtocolVersion | 0x80) : kProtocolVersion;
    buffer[3] = type.value;

    // Payload ID (64-bit int)
    byteData.setInt64(4, payloadId, Endian.big);

    // Sequence (32-bit int)
    byteData.setUint32(12, sequence, Endian.big);

    // Body Length (32-bit int)
    byteData.setUint32(16, bodyLength, Endian.big);

    // Body
    if (bodyLength > 0) {
      buffer.setRange(kHeaderLength, kHeaderLength + bodyLength, body);
    }

    // CRC32 checksum computed over header + body
    final int crc = Crc32.compute(buffer.sublist(0, kHeaderLength + bodyLength));
    byteData.setUint32(kHeaderLength + bodyLength, crc, Endian.big);

    return buffer;
  }

  /// Encodes this frame into a binary payload with magic bytes, length, CRC32 checksum,
  /// and an optional HMAC-SHA256 authentication tag if [sessionKey] is provided.
  Uint8List toBytes({Uint8List? sessionKey}) {
    final bool useAuth = sessionKey != null;
    final Uint8List prefix = _rawHeaderAndBody(authenticated: useAuth);
    if (!useAuth) {
      return prefix;
    }

    final Uint8List buffer = Uint8List(prefix.length + 32);
    buffer.setRange(0, prefix.length, prefix);
    final tag = SecurityManager.computeHmac(sessionKey, prefix);
    buffer.setRange(prefix.length, buffer.length, tag);
    return buffer;
  }

  /// Verifies the HMAC-SHA256 authentication tag of this frame using [sessionKey].
  bool verifyAuthTag(Uint8List sessionKey) {
    if (authTag == null) return false;
    final prefix = _rawHeaderAndBody(authenticated: true);
    return SecurityManager.verifyHmac(sessionKey, prefix, authTag!);
  }

  /// Parses a complete frame from a byte buffer.
  static PacketFrame? fromBytes(Uint8List bytes, {Uint8List? sessionKey}) {
    if (bytes.length < kHeaderLength + 4) return null;

    if (bytes[0] != kMagicByte0 || bytes[1] != kMagicByte1) {
      return null;
    }

    final ByteData byteData = ByteData.sublistView(bytes);
    final int rawVersion = bytes[2];
    final bool hasAuthTag = (rawVersion & 0x80) != 0;
    final int version = rawVersion & ~0x80;
    if (version != kProtocolVersion) return null;

    final int typeVal = bytes[3];
    final FrameType? type = FrameType.fromValue(typeVal);
    if (type == null) return null;

    final int payloadId = byteData.getInt64(4, Endian.big);
    final int sequence = byteData.getUint32(12, Endian.big);
    final int bodyLength = byteData.getUint32(16, Endian.big);
    if (bodyLength > kMaxFrameBodyLength) {
      return null; // Reject oversized frame
    }

    final int authTagLength = hasAuthTag ? 32 : 0;
    if (bytes.length < kHeaderLength + bodyLength + 4 + authTagLength) {
      return null; // Incomplete packet
    }

    final int expectedCrc = byteData.getUint32(kHeaderLength + bodyLength, Endian.big);
    final int actualCrc = Crc32.compute(bytes.sublist(0, kHeaderLength + bodyLength));

    if (expectedCrc != actualCrc) {
      // Checksum mismatch
      return null;
    }

    Uint8List? authTag;
    if (hasAuthTag) {
      authTag = bytes.sublist(
        kHeaderLength + bodyLength + 4,
        kHeaderLength + bodyLength + 4 + 32,
      );
      if (sessionKey != null) {
        final isValid = SecurityManager.verifyHmac(
          sessionKey,
          bytes.sublist(0, kHeaderLength + bodyLength + 4),
          authTag,
        );
        if (!isValid) {
          return null; // Checksum or tag mismatch
        }
      }
    }

    final Uint8List body = bytes.sublist(kHeaderLength, kHeaderLength + bodyLength);
    return PacketFrame(
      type: type,
      payloadId: payloadId,
      sequence: sequence,
      body: body,
      authTag: authTag,
    );
  }

  // --- Convenience Factory Constructors ---

  /// Creates a handshake init frame.
  factory PacketFrame.handshakeInit({
    required String peerId,
    required String displayName,
    required String token,
    Map<String, String> metadata = const {},
  }) {
    final payload = jsonEncode({
      'peerId': peerId,
      'displayName': displayName,
      'token': token,
      'metadata': metadata,
    });
    return PacketFrame(
      type: FrameType.handshakeInit,
      body: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// Creates a handshake ack frame.
  factory PacketFrame.handshakeAck({
    required String peerId,
    required String displayName,
    required String token,
    required bool accepted,
    String? reason,
  }) {
    final payload = jsonEncode({
      'peerId': peerId,
      'displayName': displayName,
      'token': token,
      'accepted': accepted,
      'reason': reason,
    });
    return PacketFrame(
      type: FrameType.handshakeAck,
      body: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// Creates a heartbeat frame.
  factory PacketFrame.heartbeat() {
    return PacketFrame(
      type: FrameType.heartbeat,
      body: Uint8List(0),
    );
  }

  /// Creates a disconnect frame.
  factory PacketFrame.disconnect({String? reason}) {
    final payload = jsonEncode({'reason': reason ?? 'User disconnected'});
    return PacketFrame(
      type: FrameType.disconnect,
      body: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// Creates a payload header frame.
  factory PacketFrame.payloadHeader({
    required int payloadId,
    required String payloadType,
    required int totalBytes,
    String? fileName,
  }) {
    final payload = jsonEncode({
      'type': payloadType,
      'totalBytes': totalBytes,
      'fileName': fileName,
    });
    return PacketFrame(
      type: FrameType.payloadHeader,
      payloadId: payloadId,
      body: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// Creates a payload chunk frame.
  factory PacketFrame.payloadChunk({
    required int payloadId,
    required int sequence,
    required Uint8List chunkData,
  }) {
    return PacketFrame(
      type: FrameType.payloadChunk,
      payloadId: payloadId,
      sequence: sequence,
      body: chunkData,
    );
  }

  /// Creates a payload ack frame.
  factory PacketFrame.payloadAck({
    required int payloadId,
    int sequence = 0,
  }) {
    return PacketFrame(
      type: FrameType.payloadAck,
      payloadId: payloadId,
      sequence: sequence,
      body: Uint8List(0),
    );
  }

  /// Creates a payload cancellation frame.
  factory PacketFrame.payloadCancel({
    required int payloadId,
    String? reason,
  }) {
    final payload = jsonEncode({'reason': reason ?? 'Transfer cancelled'});
    return PacketFrame(
      type: FrameType.payloadCancel,
      payloadId: payloadId,
      body: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  @override
  String toString() =>
      'PacketFrame(type: ${type.name}, payloadId: $payloadId, seq: $sequence, bodyLen: ${body.length})';
}

/// Accumulates incoming byte streams, slices frames at packet boundaries,
/// validates checksums, and emits complete [PacketFrame]s.
class PacketFramer {
  final BytesBuilder _buffer = BytesBuilder(copy: false);
  late final StreamController<PacketFrame> _frameController;
  final List<PacketFrame> _pendingFrames = [];

  PacketFramer() {
    _frameController = StreamController<PacketFrame>.broadcast(
      onListen: () {
        while (_pendingFrames.isNotEmpty && _frameController.hasListener) {
          final frame = _pendingFrames.removeAt(0);
          _frameController.add(frame);
        }
      },
    );
  }

  Stream<PacketFrame> get frames => _frameController.stream;

  /// Adds a chunk of incoming raw bytes and processes all complete frames.
  void addBytes(List<int> chunk) {
    if (_buffer.length + chunk.length > kMaxFramerBufferLength) {
      _buffer.clear();
    }
    _buffer.add(chunk);
    _processBuffer();
  }

  void _processBuffer() {
    Uint8List currentBytes = _buffer.toBytes();
    _buffer.clear();

    int offset = 0;
    while (offset <= currentBytes.length - (kHeaderLength + 4)) {
      // Find magic bytes
      if (currentBytes[offset] != kMagicByte0 ||
          currentBytes[offset + 1] != kMagicByte1) {
        offset++;
        continue;
      }

      final ByteData byteData = ByteData.sublistView(currentBytes, offset);
      final int rawVersion = currentBytes[offset + 2];
      final bool hasAuthTag = (rawVersion & 0x80) != 0;
      final int bodyLength = byteData.getUint32(16, Endian.big);
      if (bodyLength > kMaxFrameBodyLength) {
        // Discard corrupted or oversized frame header
        offset += 2;
        continue;
      }
      final int authTagLength = hasAuthTag ? 32 : 0;
      final int frameTotalLength = kHeaderLength + bodyLength + 4 + authTagLength;

      if (offset + frameTotalLength > currentBytes.length) {
        // Incomplete frame, wait for more data
        break;
      }

      final Uint8List frameBytes =
          currentBytes.sublist(offset, offset + frameTotalLength);
      final PacketFrame? frame = PacketFrame.fromBytes(frameBytes);

      if (frame != null) {
        if (_frameController.hasListener) {
          _frameController.add(frame);
        } else {
          _pendingFrames.add(frame);
        }
        offset += frameTotalLength;
      } else {
        // Corrupted frame or false magic bytes, advance by 1
        offset++;
      }
    }

    // Retain any leftover trailing partial bytes in the buffer
    if (offset < currentBytes.length) {
      _buffer.add(currentBytes.sublist(offset));
    }
  }

  /// Closes the framer controller.
  Future<void> close() async {
    _buffer.clear();
    _pendingFrames.clear();
    await _frameController.close();
  }
}

/// Fast standard CRC32 algorithm implementation with precomputed lookup table.
class Crc32 {
  static final List<int> _table = _generateTable();

  static List<int> _generateTable() {
    final List<int> table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        if ((crc & 1) != 0) {
          crc = (crc >>> 1) ^ 0xEDB88320;
        } else {
          crc = crc >>> 1;
        }
      }
      table[i] = crc & 0xFFFFFFFF;
    }
    return table;
  }

  /// Computes the 32-bit CRC checksum of [bytes].
  static int compute(List<int> bytes) {
    int crc = 0xFFFFFFFF;
    for (final int byte in bytes) {
      final int index = (crc ^ byte) & 0xFF;
      crc = (crc >>> 8) ^ _table[index];
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
