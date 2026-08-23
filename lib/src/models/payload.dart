import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Types of payload that can be transferred between peers.
enum PayloadType {
  /// Discrete byte packet (e.g. JSON, short messages, control commands).
  bytes,

  /// Stream of bytes (e.g. real-time audio, sensor readings, continuous telemetry).
  stream,

  /// File stored on disk (e.g. image, video, document) transferred with progress.
  file,
}

/// Status of a payload transfer.
enum PayloadStatus {
  /// The payload is currently being transferred (in chunks).
  inProgress,

  /// The payload transfer has succeeded.
  success,

  /// The payload transfer was cancelled by sender or receiver.
  canceled,

  /// The payload transfer failed due to an error or disconnect.
  failure,
}

/// Represents a payload to be sent or received.
class NearbyPayload {
  /// Unique 64-bit integer ID for this payload.
  final int id;

  /// Type of payload.
  final PayloadType type;

  /// The raw bytes if this is a [PayloadType.bytes] payload.
  final Uint8List? bytes;

  /// The file reference if this is a [PayloadType.file] payload.
  final File? file;

  /// Total size in bytes (if known; required for files).
  final int totalBytes;

  /// File name (used when sending files).
  final String? fileName;

  /// The byte stream if this is a [PayloadType.stream] payload.
  final Stream<List<int>>? stream;

  NearbyPayload._({
    required this.id,
    required this.type,
    this.bytes,
    this.file,
    required this.totalBytes,
    this.fileName,
    this.stream,
  });

  /// Creates a payload containing a byte array.
  factory NearbyPayload.fromBytes({
    int? id,
    required Uint8List bytes,
  }) {
    return NearbyPayload._(
      id: id ?? DateTime.now().microsecondsSinceEpoch,
      type: PayloadType.bytes,
      bytes: bytes,
      totalBytes: bytes.length,
    );
  }

  /// Creates a payload for a local file on disk.
  factory NearbyPayload.fromFile({
    int? id,
    required File file,
    String? customFileName,
  }) {
    final int length = file.existsSync() ? file.lengthSync() : 0;
    final String name = customFileName ?? file.uri.pathSegments.lastWhere(
      (s) => s.isNotEmpty,
      orElse: () => 'payload_file.bin',
    );
    return NearbyPayload._(
      id: id ?? DateTime.now().microsecondsSinceEpoch,
      type: PayloadType.file,
      file: file,
      fileName: name,
      totalBytes: length,
    );
  }

  /// Creates a payload for continuous byte streaming.
  factory NearbyPayload.fromStream({
    int? id,
    required Stream<List<int>> stream,
  }) {
    return NearbyPayload._(
      id: id ?? DateTime.now().microsecondsSinceEpoch,
      type: PayloadType.stream,
      stream: stream,
      totalBytes: -1, // Unknown/streaming
    );
  }
}

/// Real-time progress update for an ongoing payload transfer.
class PayloadTransferUpdate {
  /// The payload identifier.
  final int payloadId;

  /// The remote peer ID associated with this transfer.
  final String peerId;

  /// Total number of bytes sent or received so far.
  final int bytesTransferred;

  /// Total expected bytes (-1 for continuous streams).
  final int totalBytes;

  /// Current transfer status.
  final PayloadStatus status;

  /// Optional error message if status is [PayloadStatus.failure].
  final String? error;

  const PayloadTransferUpdate({
    required this.payloadId,
    required this.peerId,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.status,
    this.error,
  });

  /// Progress fraction between 0.0 and 1.0 (or null if totalBytes is unknown).
  double? get progress =>
      totalBytes > 0 ? (bytesTransferred / totalBytes).clamp(0.0, 1.0) : null;

  /// Percentage integer (0 to 100).
  int get percentage =>
      totalBytes > 0 ? ((bytesTransferred / totalBytes) * 100).toInt().clamp(0, 100) : 0;

  @override
  String toString() =>
      'PayloadTransferUpdate(id: $payloadId, peer: $peerId, $bytesTransferred/$totalBytes bytes, status: ${status.name})';
}
