import 'dart:async';
import 'dart:typed_data';
import '../protocol/packet_framer.dart';

/// Abstract interface representing an active transport channel with a remote peer.
abstract class NearbyTransport {
  /// Unique identifier of the remote peer connected on this transport.
  String get peerId;

  /// Optional authenticated session key used for signing outgoing frames.
  Uint8List? get sessionKey;
  set sessionKey(Uint8List? key);

  /// Stream of decoded packet frames received from the remote peer.
  Stream<PacketFrame> get incomingFrames;

  /// Whether this transport connection is currently active and open.
  bool get isConnected;

  /// Sends a packet frame over the wire.
  Future<void> sendFrame(PacketFrame frame);

  /// Sends raw bytes through the transport.
  Future<void> sendRaw(Uint8List data);

  /// Closes the transport connection gracefully.
  Future<void> close();
}
