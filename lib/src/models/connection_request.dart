import 'peer.dart';

/// Represents an incoming or outgoing connection request with a peer.
class ConnectionRequest {
  /// The peer initiating or targeted by the connection request.
  final Peer peer;

  /// Short Authentication String (SAS) / 4-6 digit numeric PIN generated
  /// from the cryptographic handshake tokens for out-of-band visual verification.
  final String authenticationPin;

  /// Custom metadata or connection context sent with the request.
  final Map<String, String> metadata;

  /// Timestamp when the connection request was received.
  final DateTime timestamp;

  const ConnectionRequest({
    required this.peer,
    required this.authenticationPin,
    this.metadata = const {},
    required this.timestamp,
  });

  @override
  String toString() =>
      'ConnectionRequest(peer: ${peer.displayName} (${peer.id}), pin: $authenticationPin)';
}

/// Response status to a connection request.
enum ConnectionResponseStatus {
  accepted,
  rejected,
  timedOut,
}

/// Connection response sent back to the initiator.
class ConnectionResponse {
  final String peerId;
  final ConnectionResponseStatus status;
  final String? reason;

  const ConnectionResponse({
    required this.peerId,
    required this.status,
    this.reason,
  });
}
