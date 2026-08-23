# nearby

A high-performance, cross-platform peer-to-peer networking plugin for Flutter — offering functionality equivalent to **Apple's Multipeer Connectivity** and **Google's Nearby Connections API**.

Built with pure Dart socket orchestration on top of **[Bonsoir](https://pub.dev/packages/bonsoir)** (mDNS / Bonjour) and **[Universal BLE](https://pub.dev/packages/universal_ble)** (Bluetooth Low Energy).

---

## ✨ Features

- **🚀 Hybrid Discovery**: Simultaneous dual-channel discovery combining zero-config local network broadcast (mDNS / Bonjour) with Bluetooth Low Energy (BLE) peripheral/central scanning.
- **⚡ High-Throughput Direct TCP Sockets**: Primary payload channel uses framing-optimized raw TCP sockets with zero latency and high file transfer rates over local network (Wi-Fi or Ethernet).
- **📶 Seamless BLE Fallback**: Automatic GATT characteristic fallback when peers are in Bluetooth proximity but not connected to the same Wi-Fi network.
- **🔒 Flexible Security Handshake**:
  - **Auto-Accept Mode**: Rapid pairing for automated devices.
  - **SAS PIN Verification**: Cryptographically derived Short Authentication String (4 or 6-digit symmetric PIN) for visual user verification on both screens.
- **📦 Multi-Type Payload Engine**:
  - **Bytes**: Fast, reliable byte packets for messages, control commands, and JSON payloads.
  - **File**: High-speed chunked file transfers with live progress callbacks, percentage tracking, and cancellation.
  - **Stream**: Real-time continuous byte streaming for audio, video chunks, and sensor telemetry.
- **🖥️ True Cross-Platform**: Android, iOS, macOS, Windows, and Linux.

---

## 🏗️ Architecture & Protocol

```
+-------------------------------------------------------------+
|                      NearbyService                          |
+-------------------------------------------------------------+
|                    NearbySession Engine                     |
+------------------------------+------------------------------+
|     Discovery Coordinator    |        Payload Engine        |
|  +------------+------------+ | +---------+--------+-------+ |
|  |   Bonsoir  |  Univ. BLE | | |  Bytes  |  File  | Stream| |
|  |   (mDNS)   |   (BLE)    | | +---------+--------+-------+ |
+--+------------+------------+-+---------------+--------------+
|       Packet Framer (Magic Bytes + Length + CRC32)          |
+------------------------------+------------------------------+
|   TCP Socket (High Bandwidth)|   BLE GATT (Direct Fallback) |
+------------------------------+------------------------------+
```

---

## 📱 Platform Setup & Permissions

### Android (`android/app/src/main/AndroidManifest.xml`)

Add the following permissions:

```xml
<!-- Local Network & mDNS -->
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" android:usesPermissionFlags="neverForLocation" />

<!-- Bluetooth & Proximity -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

### iOS (`ios/Runner/Info.plist`) & macOS (`macos/Runner/Info.plist`)

Add the keys for Bluetooth and Local Network usage, including your custom Bonjour service name:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover and communicate with nearby devices.</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Used to advertise this device to nearby peers.</string>
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover and connect to nearby peers over Wi-Fi and local network.</string>
<key>NSBonjourServices</key>
<array>
    <string>_nearby-app._tcp</string>
</array>
```

---

## 🚀 Quick Start

### 1. Initialize `NearbyService`

```dart
import 'package:nearby/nearby.dart';

final nearby = NearbyService(
  localDisplayName: 'My iPad Pro',
);
```

### 2. Advertise Device

```dart
await nearby.startAdvertising(
  options: const AdvertisingOptions(
    serviceId: 'nearby-app',
    strategy: DiscoveryStrategy.hybrid,
    securityMode: SecurityMode.pinVerification, // or SecurityMode.autoAccept
  ),
);
```

### 3. Discover Nearby Peers

```dart
// Listen to discovered peers
nearby.discoveredPeersStream.listen((peers) {
  for (final peer in peers) {
    print('Found peer: ${peer.displayName} (${peer.id}) via ${peer.discoveredVia.name}');
  }
});

await nearby.startDiscovery(
  options: const DiscoveryOptions(
    serviceId: 'nearby-app',
    strategy: DiscoveryStrategy.hybrid,
  ),
);
```

### 4. Connect & Handshake

```dart
// Connect to a discovered peer
final success = await nearby.requestConnection(peer);

// On advertiser device: handle incoming connection requests
nearby.connectionRequestsStream.listen((request) {
  print('Incoming request from ${request.peer.displayName} with PIN: ${request.authenticationPin}');
  // Accept connection:
  nearby.acceptConnection(request.peer.id);
  // Or reject:
  // nearby.rejectConnection(request.peer.id, reason: 'Busy');
});
```

### 5. Send & Receive Payloads

#### Send Byte Packet (Messages / Commands)
```dart
final bytes = Uint8List.fromList(utf8.encode('Hello Nearby Peer!'));
await nearby.sendBytes(peerId, bytes);

// Or broadcast to all connected peers
await nearby.sendBytesToAll(bytes);
```

#### Send File with Progress Updates
```dart
final file = File('/path/to/my_image.png');
await nearby.sendFile(peerId, file, customFileName: 'vacation.png');

// Track live progress
nearby.payloadProgressStream.listen((update) {
  print('Payload #${update.payloadId}: ${update.percentage}% (${update.bytesTransferred}/${update.totalBytes} bytes)');
});
```

#### Stream Continuous Telemetry / Audio
```dart
final streamController = StreamController<List<int>>();
await nearby.sendStream(peerId, streamController.stream);

// Push stream chunks in real-time
streamController.add([1, 2, 3, 4]);
```

#### Receive Incoming Payloads
```dart
nearby.payloadReceivedStream.listen((payload) {
  if (payload.type == PayloadType.bytes) {
    final text = utf8.decode(payload.bytes!);
    print('Received message: $text');
  } else if (payload.type == PayloadType.file) {
    print('Received file at: ${payload.file!.path} (${payload.fileName})');
  } else if (payload.type == PayloadType.stream) {
    print('Receiving real-time stream...');
    payload.stream!.listen((chunk) {
      // Process stream chunk
    });
  }
});
```

---

## 🧪 Testing

Run all unit tests, framing verifications, and mock integration suites:

```bash
flutter test
```
