import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'ble_constants.dart';

/// Callback to perform a single chunk write attempt.
typedef BleWriteChunkCallback = Future<void> Function(Uint8List chunk);

/// Helper for synchronizing and chunking raw payload bytes over BLE with backoff retries.
class BleChunkSender {
  Future<void> _writeQueue = Future.value();

  /// Enqueues an asynchronous write operation sequentially.
  Future<T> synchronized<T>(Future<T> Function() operation) {
    final next = _writeQueue.then((_) => operation(), onError: (_) => operation());
    _writeQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Sends [data] chunk-by-chunk using [writeChunk].
  ///
  /// Automatically slices [data] based on [mtu] (capped at [kBleMaxChunkSize]).
  /// Automatically retries failed chunks up to [maxAttempts] with linear-exponential backoff.
  Future<void> sendChunks({
    required Uint8List data,
    required int mtu,
    required BleWriteChunkCallback writeChunk,
    required bool Function() isClosed,
    int maxAttempts = 8,
    Duration baseBackoff = const Duration(milliseconds: 15),
  }) {
    return synchronized(() async {
      if (isClosed()) {
        throw StateError('Cannot send raw data on closed BLE transport');
      }

      final int maxChunk = min(mtu, kBleMaxChunkSize);
      int offset = 0;

      while (offset < data.length) {
        if (isClosed()) break;

        final int chunkSize =
            (data.length - offset < maxChunk) ? (data.length - offset) : maxChunk;
        final Uint8List chunk = data.sublist(offset, offset + chunkSize);

        int attempts = 0;
        bool sent = false;

        while (!sent && attempts < maxAttempts && !isClosed()) {
          attempts++;
          try {
            await writeChunk(chunk);
            sent = true;
          } catch (e) {
            if (attempts >= maxAttempts) rethrow;
            await Future<void>.delayed(baseBackoff * attempts);
          }
        }

        offset += chunkSize;
      }
    });
  }
}
