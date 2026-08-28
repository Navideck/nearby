# nearby

A robust, multiplatform peer-to-peer discovery, secure data transfer, and connectionless broadcasting plugin for Flutter.

Inspired by Apple Multipeer Connectivity and Google Nearby Connections, `nearby` supports dual communication paradigms over local Wi-Fi / LAN (mDNS + UDP/TCP) and Bluetooth Low Energy (BLE).

---

## 🌟 Dual Communication Paradigms

`nearby` supports two complementary communication modes under a unified API:

```
                                  ┌─────────────────────────┐
                                  │      NearbyService      │
                                  └───────────┬─────────────┘
                                              │
                      ┌───────────────────────┴───────────────────────┐
                      ▼                                               ▼
         ┌─────────────────────────┐                     ┌─────────────────────────┐
         │   Connected Sessions    │                     │   Broadcast Channels    │
         │      (1:1 P2P)          │                     │      (1:Many)           │
         └────────────┬────────────┘                     └────────────┬────────────┘
                      │                                               │
        ┌─────────────┴─────────────┐                   ┌─────────────┴─────────────┐
        ▼                           ▼                   ▼                           ▼
   TCP Sockets                 BLE GATT           UDP Multicast              BLE Advertisements
  (LAN / Wi-Fi)              (Peripheral)         (Datagrams)               (Manufacturer Data)
```

| Feature | 🤝 Connected Sessions (1:1) | 📡 Broadcast Channels (1:Many) |
| :--- | :--- | :--- |
| **Topology** | 1-to-1 Point-to-Point | 1-to-Many Unicast / Multicast |
| **Connection Overhead** | Requires connection + SAS PIN handshake | **Zero connection overhead** (Stateless) |
| **Device Scale** | Bound by platform TCP/GATT limits (~3–7 BLE) | **Unlimited listeners** simultaneously |
| **Transports** | TCP sockets & BLE GATT characteristics | UDP Multicast datagrams & BLE Advertisements |
| **Data Types** | Byte packets, large disk files, continuous streams | High-frequency raw byte datagrams (0 framing) |
| **Best For** | File sharing, remote control, chat, audio streaming | Timecode sync, mesh beacons, tally lights, presence |

---

## 📦 Features

- **Multiplatform**: iOS, macOS, Android, Windows, Linux.
- **Hybrid Transports**: Seamlessly multiplexes Wi-Fi/LAN and Bluetooth Low Energy.
- **Multiplexed BLE Scanning**: Centralized BLE scan dispatcher prevents callback collisions when discovery and broadcast channels run concurrently.
- **Diffie-Hellman SAS PIN Verification**: Secure session establishment with short numeric authentication strings (SAS).
- **Chunked Payload Engine**: Reliable chunking, interleaving, and CRC32 verification for byte messages, files, and live streams.
- **Connectionless Broadcast Channels**: Ultra-low latency UDP multicast and BLE manufacturer advertising for 1:Many real-time broadcasting.

---

## ⚙️ Platform Permissions & Setup

### Android (`android/app/src/main/AndroidManifest.xml`)

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Local Network Permissions -->
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
    <uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />

    <!-- Bluetooth Permissions (Android 12+) -->
    <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

    <!-- Legacy Bluetooth Permissions (Android 11 and lower) -->
    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
</manifest>
```

### iOS (`ios/Runner/Info.plist`) & macOS (`macos/Runner/Info.plist`)

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

### macOS Entitlements (`macos/Runner/*.entitlements`)

Enable network client/server and Bluetooth in **both** `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.server</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.device.bluetooth</key>
<true/>
```

---

## 🚀 Usage Guide

### 1. Initialize `NearbyService`

```dart
import 'package:nearby/nearby.dart';

final nearby = NearbyService(
  localDisplayName: 'Camera A',
  // Optional: persistent peer ID across restarts (random hex ID by default)
  localPeerId: 'camera-node-01',
);
```

---

### 2. Mode A: Connection-Oriented Sessions (1:1)

#### A. Start Advertising Presence
```dart
await nearby.startAdvertising(
  options: const AdvertisingOptions(
    serviceId: 'production-set',
    strategy: DiscoveryStrategy.hybrid,
    securityMode: SecurityMode.pinVerification, // or SecurityMode.autoAccept
  ),
);
```

#### B. Discover Peers & Connect
```dart
// Listen to discovered peers
nearby.discoveredPeersStream.listen((peers) {
  for (final peer in peers) {
    print('Found peer: ${peer.displayName} (${peer.id}) via ${peer.discoveredVia.name}');
  }
});

await nearby.startDiscovery(
  options: const DiscoveryOptions(
    serviceId: 'production-set',
    strategy: DiscoveryStrategy.hybrid,
  ),
);

// Connect to a peer (TCP first, BLE fallback)
final connected = await nearby.requestConnection(peer);
```

#### C. Handle Inbound Connection & PIN Verification
```dart
// Advertiser verifies PIN with initiator
nearby.connectionRequestsStream.listen((request) {
  print('Request from ${request.peer.displayName} with PIN: ${request.authenticationPin}');
  // Verify PIN visually, then accept:
  nearby.acceptConnection(request.peer.id);
});
```

#### D. Transfer Bytes, Files, or Streams
```dart
// 1. Send byte message
await nearby.sendBytes(peerId, Uint8List.fromList(utf8.encode('Take 1 Action!')));

// 2. Send file with progress tracking
nearby.payloadProgressStream.listen((update) {
  print('Transfer #${update.payloadId}: ${update.percentage}%');
});
await nearby.sendFile(peerId, File('/path/to/script.pdf'));

// 3. Pipe live byte stream
final streamController = StreamController<List<int>>();
await nearby.sendStream(peerId, streamController.stream);
streamController.add([0x01, 0x02, 0x03]);

// 4. Receive incoming payloads
nearby.payloadReceivedStream.listen((payload) {
  switch (payload.type) {
    case PayloadType.bytes:
      print('Received: ${utf8.decode(payload.bytes!)}');
    case PayloadType.file:
      print('File saved at: ${payload.file!.path}');
    case PayloadType.stream:
      payload.stream!.listen((chunk) => print('Stream chunk: ${chunk.length} bytes'));
  }
});
```

---

### 3. Mode B: Connectionless Broadcasts (1:Many)

BroadcastChannels allow 1 sender to broadcast high-frequency datagrams to unlimited listeners via UDP Multicast and BLE Manufacturer Data without pairing or connection overhead.

#### A. Dedicated Broadcast Channel
```dart
// Create a dedicated channel
final channel = nearby.createBroadcastChannel(
  const BroadcastChannelConfig(
    channelId: 'navideck-tc',
    strategy: DiscoveryStrategy.hybrid,
    multicastAddress: '239.255.0.1',
    multicastPort: 9876,
    bleCompanyId: 0xFFFF,
  ),
);

// Start listening for incoming broadcast datagrams
await channel.startListening();
channel.stream.listen((packet) {
  print('Broadcast from ${packet.senderId} via ${packet.medium.name}: ${packet.data.length} bytes');
});

// Broadcast datagrams to all nearby devices
await channel.startBroadcasting();
await channel.send(Uint8List.fromList([0x01, 0x02, 0x03, 0x04]), localName: 'Slate-Master');
```

#### B. Convenience Service Broadcasts
```dart
// Quick broadcast on default channel
await nearby.broadcast(Uint8List.fromList([0xAA, 0xBB]));

// Listen on default broadcast stream
nearby.onBroadcastReceived.listen((packet) {
  print('Received broadcast: ${packet.data}');
});
```

---

### 4. Teardown & Lifecycle

```dart
// Disconnect individual peers or all
await nearby.disconnectPeer(peerId);
await nearby.disconnectAll();

// Stop discovery / advertising
await nearby.stopDiscovery();
await nearby.stopAdvertising();

// Full cleanup (closes all sockets, BLE scans, and broadcast channels)
await nearby.dispose();
```

---

## 📖 API Reference

### `NearbyService`

| API | Type | Description |
| :--- | :--- | :--- |
| `startAdvertising({options})` | Method | Starts mDNS & BLE peripheral advertising. |
| `stopAdvertising()` | Method | Stops advertising and closes inbound servers. |
| `startDiscovery({options})` | Method | Starts browsing for nearby advertising peers. |
| `stopDiscovery()` | Method | Stops discovery and stops scanning. |
| `requestConnection(peer)` | Method | Requests secure connection with Diffie-Hellman handshake. |
| `acceptConnection(peerId)` | Method | Accepts incoming connection request after PIN check. |
| `rejectConnection(peerId)` | Method | Rejects incoming connection request. |
| `sendBytes(peerId, bytes)` | Method | Sends byte payload to connected peer. |
| `sendBytesToAll(bytes)` | Method | Sends byte payload to all connected peers. |
| `sendFile(peerId, file)` | Method | Sends file payload with progress tracking. |
| `sendStream(peerId, stream)` | Method | Pipes continuous byte stream to connected peer. |
| `createBroadcastChannel(config)`| Method | Creates and registers managed 1:Many `BroadcastChannel`. |
| `broadcast(data, ...)` | Method | Convenience method to broadcast datagram to listeners. |
| `onBroadcastReceived` | Stream | Stream of datagrams from default broadcast channel. |
| `discoveredPeersStream` | Stream | Live list of discovered peers. |
| `connectionRequestsStream` | Stream | Inbound connection requests with SAS PINs. |
| `payloadReceivedStream` | Stream | Inbound payload stream (`Bytes`, `File`, `Stream`). |
| `dispose()` | Method | Cleanly shuts down all sessions, servers, and channels. |

---

## 🧪 Testing

Run the full test suite (65+ unit & integration tests):

```bash
flutter test
```

## 📄 License

MIT License.
