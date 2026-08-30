import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

typedef BleScanCallback = void Function(BleDevice device);

/// Shares a scan without replacing the application's scan callback.
class BleScanDispatcher {
  BleScanDispatcher._();
  static final BleScanDispatcher instance = BleScanDispatcher._();
  final Set<BleScanCallback> _listeners = {};
  StreamSubscription<BleDevice>? _subscription;
  Future<void> _operation = Future.value();
  bool _ownsScan = false;

  /// Restores an application's previous scan/filter after Nearby releases BLE.
  Future<void> Function()? resumeInterruptedScan;
  bool get isScanning => _subscription != null;
  int get listenerCount => _listeners.length;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _operation.then((_) => action());
    _operation = next.catchError((Object _) {});
    return next;
  }

  Future<void> addListener(
    BleScanCallback callback, {
    ScanFilter? scanFilter,
  }) => _serialize(() async {
    _listeners.add(callback);
    if (_subscription != null) return;
    _subscription = UniversalBle.scanStream.listen(_dispatchScanResult);
    var interrupted = false;
    try {
      _ownsScan = !await UniversalBle.isScanning();
      if (!_ownsScan) {
        await UniversalBle.stopScan();
        interrupted = true;
      }
      // Unfiltered: simultaneous listeners can use different carriers.
      await UniversalBle.startScan(
        platformConfig: PlatformConfig(
          android: AndroidOptions(scanMode: AndroidScanMode.lowLatency),
        ),
      );
    } catch (_) {
      _listeners.remove(callback);
      await _subscription?.cancel();
      _subscription = null;
      if (interrupted) {
        await (resumeInterruptedScan ?? UniversalBle.startScan)();
      }
      _ownsScan = false;
      rethrow;
    }
  });

  Future<void> removeListener(BleScanCallback callback) => _serialize(() async {
    _listeners.remove(callback);
    if (_listeners.isEmpty) await _stop();
  });

  Future<void> _stop() async {
    final wasScanning = _subscription != null;
    await _subscription?.cancel();
    _subscription = null;
    if (wasScanning) {
      await UniversalBle.stopScan();
      if (!_ownsScan) await (resumeInterruptedScan ?? UniversalBle.startScan)();
    }
    _ownsScan = false;
  }

  void _dispatchScanResult(BleDevice device) {
    for (final listener in List.of(_listeners)) {
      listener(device);
    }
  }

  @visibleForTesting
  void dispatchScanResultForTesting(BleDevice device) =>
      _dispatchScanResult(device);

  Future<void> reset() => _serialize(() async {
    _listeners.clear();
    await _stop();
  });
}
