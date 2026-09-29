## 0.1.0

* Initial release.
* Advertising and discovery of nearby peers over Wi-Fi/LAN (mDNS) and Bluetooth Low Energy.
* 1:1 connected sessions over TCP sockets or BLE GATT, with hybrid connections preferring TCP and falling back to BLE.
* Sending arbitrary bytes, files, and streams between connected peers.
* Inbound connection requests with optional PIN verification.
* Encrypted and authenticated sessions backed by the shared protocol and security layer.
* Connectionless 1:many `BroadcastChannel` datagrams over UDP multicast and BLE advertisements.
* Support for Android, iOS, macOS, Windows, and Linux.
