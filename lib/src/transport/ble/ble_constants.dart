/// Standard Nearby Bluetooth GATT Service and Characteristic UUIDs (dedicated 128-bit).
const String kNearbyBleServiceUuid = 'fa5a0001-9a3b-4654-8fe2-8a96d11f81d1';
const String kNearbyBleTxCharUuid = 'fa5a0002-9a3b-4654-8fe2-8a96d11f81d1';
const String kNearbyBleRxCharUuid = 'fa5a0003-9a3b-4654-8fe2-8a96d11f81d1';

/// Minimum valid Bluetooth Low Energy ATT MTU (23 bytes).
const int kBleMinMtu = 23;

/// Maximum single-write chunk length capped to the Android GATT 512-byte max
/// attribute length.
const int kBleMaxChunkSize = 512;

/// Default MTU payload capacity when negotiation is pending.
const int kBleDefaultMtu = 240;

/// Normalizes a BLE device identifier (UUID or MAC address) for case-insensitive indexing.
String normalizeDeviceId(String deviceId) => deviceId.trim().toLowerCase();
