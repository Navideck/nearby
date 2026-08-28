import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

typedef BleScanCallback = void Function(BleDevice device);

/// Multiplexes Bluetooth Low Energy scan results across multiple concurrent listeners
/// to avoid race conditions and callback overwrites on UniversalBle.onScanResult.
class BleScanDispatcher {
  BleScanDispatcher._();
  static final BleScanDispatcher instance = BleScanDispatcher._();

  final Set<BleScanCallback> _listeners = {};
  bool _isScanning = false;

  bool get isScanning => _isScanning;
  int get listenerCount => _listeners.length;

  /// Registers a scan [callback] and starts BLE scanning if not already active.
  Future<void> addListener(BleScanCallback callback, {ScanFilter? scanFilter}) async {
    _listeners.add(callback);
    if (!_isScanning) {
      _isScanning = true;
      UniversalBle.onScanResult = _dispatchScanResult;
      try {
        if (scanFilter != null) {
          await UniversalBle.startScan(scanFilter: scanFilter);
        } else {
          await UniversalBle.startScan();
        }
      } catch (_) {
        try {
          await UniversalBle.startScan();
        } catch (_) {}
      }
    }
  }

  /// Removes a scan [callback] and stops scanning when no listeners remain.
  Future<void> removeListener(BleScanCallback callback) async {
    _listeners.remove(callback);
    if (_listeners.isEmpty && _isScanning) {
      _isScanning = false;
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }

  void _dispatchScanResult(BleDevice device) {
    if (!_isScanning) return;
    for (final listener in List.of(_listeners)) {
      try {
        listener(device);
      } catch (_) {}
    }
  }

  /// Manually dispatches a scan result to registered listeners (for testing).
  @visibleForTesting
  void dispatchScanResultForTesting(BleDevice device) {
    _dispatchScanResult(device);
  }

  /// Clears all listeners and stops scanning.
  Future<void> reset() async {
    _listeners.clear();
    if (_isScanning) {
      _isScanning = false;
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
  }
}
