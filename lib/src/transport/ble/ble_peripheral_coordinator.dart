import 'dart:async';

/// Coordinates shared access to the platform's single `UniversalBlePeripheral`
/// advertiser across Nearby's GATT server discovery, connectionless
/// `BroadcastChannel`s, and host-application peripheral services (such as BLE HID).
class BlePeripheralCoordinator {
  BlePeripheralCoordinator._();

  static final BlePeripheralCoordinator instance = BlePeripheralCoordinator._();

  final Set<Object> _exclusiveOwners = {};

  /// Optional predicate queried before opportunistic connectionless BLE
  /// broadcast ticks. Return `true` when the host application owns BLE
  /// peripheral advertising so `BroadcastChannel` skips BLE advertising ticks
  /// instead of overwriting or stopping the host's advertisement.
  FutureOr<bool> Function()? isExternalAdvertisingActive;

  /// Optional callback invoked when Nearby releases its last exclusive
  /// peripheral owner so the host application can restore its own peripheral
  /// advertising if desired.
  Future<void> Function()? resumeInterruptedAdvertising;

  /// Registers [owner] as an active exclusive BLE peripheral advertiser.
  void acquireExclusive(Object owner) {
    _exclusiveOwners.add(owner);
  }

  /// Whether [owner] currently holds an exclusive BLE peripheral lease.
  bool ownsExclusive(Object owner) => _exclusiveOwners.contains(owner);

  /// Releases [owner]'s exclusive BLE peripheral lease and notifies
  /// [resumeInterruptedAdvertising] when the last internal owner releases.
  Future<void> releaseExclusive(Object owner) async {
    final removed = _exclusiveOwners.remove(owner);
    if (removed &&
        _exclusiveOwners.isEmpty &&
        resumeInterruptedAdvertising != null) {
      await resumeInterruptedAdvertising!();
    }
  }

  /// Whether any exclusive peripheral owner (Nearby GATT server or host app)
  /// currently owns BLE peripheral advertising.
  Future<bool> isExclusiveAdvertisingActive() async {
    if (_exclusiveOwners.isNotEmpty) return true;
    final externalCheck = isExternalAdvertisingActive;
    if (externalCheck != null && await externalCheck()) return true;
    return false;
  }

  /// Resets all coordinator leases and callbacks (useful for tests).
  void reset() {
    _exclusiveOwners.clear();
    isExternalAdvertisingActive = null;
    resumeInterruptedAdvertising = null;
  }
}
