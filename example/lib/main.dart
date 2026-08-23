import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:nearby/nearby.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NearbyExampleApp());
}

class NearbyExampleApp extends StatelessWidget {
  const NearbyExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nearby Connectivity Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1), // Indigo accent
          secondary: Color(0xFF10B981), // Emerald accent
          surface: Color(0xFF1E1E2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF11111B),
        cardColor: const Color(0xFF1E1E2E),
        useMaterial3: true,
      ),
      home: const NearbyHomeScreen(),
    );
  }
}

class NearbyHomeScreen extends StatefulWidget {
  const NearbyHomeScreen({super.key});

  @override
  State<NearbyHomeScreen> createState() => _NearbyHomeScreenState();
}

class _NearbyHomeScreenState extends State<NearbyHomeScreen> {
  late final NearbyService _nearbyService;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();

  DiscoveryStrategy _selectedStrategy = DiscoveryStrategy.hybrid;
  SecurityMode _securityMode = SecurityMode.pinVerification;
  final String _serviceId = 'nearby-demo';

  List<Peer> _discoveredPeers = [];
  final List<String> _chatMessages = [];
  final Map<int, PayloadTransferUpdate> _activeTransfers = {};
  final Map<String, String?> _pendingConnections = {};

  StreamSubscription? _discoverySub;
  StreamSubscription? _requestSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _payloadSub;
  StreamSubscription? _progressSub;

  StreamController<List<int>>? _activeSensorStream;
  Timer? _sensorTimer;
  int _sensorCounter = 0;
  String? _selectedPeerId;
  Directory? _documentsDir;

  @override
  void initState() {
    super.initState();
    _initNearbyService();
    _initStorageDir();
    _requestPermissions();
  }

  void _initNearbyService() {
    _nearbyService = NearbyService(
      localDisplayName: 'Flutter Device ${DateTime.now().millisecond}',
    );
    _nameController.text = _nearbyService.localDisplayName;

    // Listen to discovered peers
    _discoverySub = _nearbyService.discoveredPeersStream.listen((peers) {
      if (mounted) {
        setState(() {
          _discoveredPeers = peers;
        });
      }
    });

    // Listen to incoming connection requests
    _requestSub = _nearbyService.connectionRequestsStream.listen((request) {
      if (mounted) {
        _showIncomingRequestDialog(request);
      }
    });

    // Listen to peer connection state changes
    _stateSub = _nearbyService.peerStateStream.listen((update) {
      if (mounted) {
        setState(() {
          if (update.state == PeerConnectionState.authenticating) {
            _pendingConnections[update.peer.id] = update.sasPin;
          } else if (update.state == PeerConnectionState.connected) {
            _pendingConnections.remove(update.peer.id);
            _selectedPeerId ??= update.peer.id;
          } else if (update.state == PeerConnectionState.disconnected) {
            _pendingConnections.remove(update.peer.id);
            if (_selectedPeerId == update.peer.id) {
              final remaining = _nearbyService.connectedPeers;
              _selectedPeerId = remaining.isNotEmpty ? remaining.first.id : null;
            }
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${update.peer.displayName}: ${update.state.name.toUpperCase()}${update.sasPin != null ? ' (PIN: ${update.sasPin})' : ''}',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });

    // Listen to received payloads
    _payloadSub = _nearbyService.payloadReceivedStream.listen((payload) {
      if (payload.type == PayloadType.bytes && payload.bytes != null) {
        final text = utf8.decode(payload.bytes!, allowMalformed: true);
        if (mounted) {
          setState(() {
            _chatMessages.add('📥 Remote: $text');
          });
          _scrollToBottom();
        }
      } else if (payload.type == PayloadType.file && payload.file != null) {
        if (mounted) {
          setState(() {
            _chatMessages.add('📁 Received File: ${payload.fileName} (${payload.totalBytes} bytes)');
          });
          _scrollToBottom();
        }
      } else if (payload.type == PayloadType.stream && payload.stream != null) {
        if (mounted) {
          setState(() {
            _chatMessages.add('🌊 Receiving continuous live stream...');
          });
        }
        payload.stream!.listen((data) {
          // Stream data chunk received
        });
      }
    });

    // Listen to transfer progress
    _progressSub = _nearbyService.payloadProgressStream.listen((update) {
      if (mounted) {
        setState(() {
          _activeTransfers[update.payloadId] = update;
          if (update.status == PayloadStatus.success ||
              update.status == PayloadStatus.canceled ||
              update.status == PayloadStatus.failure) {
            Future.delayed(const Duration(seconds: 4), () {
              if (mounted) {
                setState(() {
                  _activeTransfers.remove(update.payloadId);
                });
              }
            });
          }
        });
      }
    });
  }

  Future<void> _initStorageDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      if (mounted) {
        setState(() {
          _documentsDir = dir;
          _nearbyService.storageDirectory = dir;
        });
      }
    } catch (e) {
      debugPrint('Failed to get application documents directory: $e');
    }
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
        Permission.nearbyWifiDevices,
      ].request();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _toggleAdvertising() async {
    if (_nearbyService.isAdvertising) {
      await _nearbyService.stopAdvertising();
    } else {
      await _nearbyService.startAdvertising(
        options: AdvertisingOptions(
          serviceId: _serviceId,
          strategy: _selectedStrategy,
          securityMode: _securityMode,
        ),
      );
    }
    if (mounted) setState(() {});
  }

  Future<void> _toggleDiscovery() async {
    if (_nearbyService.isDiscovering) {
      await _nearbyService.stopDiscovery();
    } else {
      await _nearbyService.startDiscovery(
        options: DiscoveryOptions(
          serviceId: _serviceId,
          strategy: _selectedStrategy,
        ),
      );
    }
    if (mounted) setState(() {});
  }

  void _showIncomingRequestDialog(ConnectionRequest request) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text('Incoming Connection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Peer: ${request.peer.displayName}'),
            const SizedBox(height: 8),
            Text('Transport: ${request.peer.discoveredVia.name.toUpperCase()}'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF282A36),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFF6366F1)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Verification PIN: ', style: TextStyle(color: Colors.grey)),
                  Text(
                    request.authenticationPin,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 4,
                      color: Color(0xFF10B981),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Verify that the other device displays the same PIN.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _nearbyService.rejectConnection(request.peer.id, reason: 'Declined by user');
            },
            child: const Text('Reject', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () {
              Navigator.pop(ctx);
              _nearbyService.acceptConnection(request.peer.id);
            },
            child: const Text('Accept & Connect', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _connectToPeer(Peer peer) async {
    setState(() {
      _pendingConnections[peer.id] = null;
    });

    try {
      final success = await _nearbyService.requestConnection(peer);
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection to ${peer.displayName} was declined or timed out.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error connecting to ${peer.displayName}: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _pendingConnections.remove(peer.id);
        });
      }
    }
  }

  void _sendMessage() {
    final text = _msgController.text.trim();
    if (text.isEmpty || _selectedPeerId == null) return;

    final bytes = Uint8List.fromList(utf8.encode(text));
    _nearbyService.sendBytes(_selectedPeerId!, bytes);

    setState(() {
      _chatMessages.add('📤 You: $text');
    });
    _msgController.clear();
    _scrollToBottom();
  }

  Future<void> _sendSampleFile() async {
    if (_selectedPeerId == null || _documentsDir == null) return;

    final sampleFile = File('${_documentsDir!.path}/sample_photo.bin');
    final sampleBytes = Uint8List.fromList(List.generate(256 * 1024, (i) => (i * 7) % 256));
    sampleFile.writeAsBytesSync(sampleBytes);

    await _nearbyService.sendFile(
      _selectedPeerId!,
      sampleFile,
      customFileName: 'nearby_test_image.jpg',
    );

    setState(() {
      _chatMessages.add('📤 Sent File: nearby_test_image.jpg (256 KB)');
    });
    _scrollToBottom();
  }

  void _toggleLiveStream() {
    if (_selectedPeerId == null) return;

    if (_activeSensorStream != null) {
      _sensorTimer?.cancel();
      _sensorTimer = null;
      _activeSensorStream?.close();
      _activeSensorStream = null;
      setState(() {
        _chatMessages.add('⏹ Live sensor stream stopped');
      });
    } else {
      _activeSensorStream = StreamController<List<int>>.broadcast();
      _nearbyService.sendStream(_selectedPeerId!, _activeSensorStream!.stream);

      _sensorCounter = 0;
      _sensorTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
        _sensorCounter++;
        final data = utf8.encode('Tick #$_sensorCounter (Sensors: X=${_sensorCounter % 10}, Y=${_sensorCounter * 2 % 100})');
        _activeSensorStream?.add(data);
      });

      setState(() {
        _chatMessages.add('▶ Streaming live sensor telemetry...');
      });
    }
    _scrollToBottom();
  }

  @override
  void dispose() {
    _sensorTimer?.cancel();
    _activeSensorStream?.close();
    _discoverySub?.cancel();
    _requestSub?.cancel();
    _stateSub?.cancel();
    _payloadSub?.cancel();
    _progressSub?.cancel();
    unawaited(_nearbyService.dispose());
    _nameController.dispose();
    _msgController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connectedPeers = _nearbyService.connectedPeers;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Cross-Platform Sync'),
        backgroundColor: const Color(0xFF1E1E2E),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Control Card
            _buildControlCard(),
            const SizedBox(height: 16),

            // Discovered Peers
            _buildDiscoveredPeersCard(),
            const SizedBox(height: 16),

            // Connected Sessions & Data Transfer
            if (connectedPeers.isNotEmpty) ...[
              _buildConnectedSessionCard(connectedPeers),
              const SizedBox(height: 16),
              _buildDataTransferCard(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildControlCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Configuration & Controls',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<DiscoveryStrategy>(
              initialValue: _selectedStrategy,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Discovery Medium',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: DiscoveryStrategy.hybrid,
                  child: Text('Hybrid (mDNS + BLE)', overflow: TextOverflow.ellipsis),
                ),
                DropdownMenuItem(
                  value: DiscoveryStrategy.mdnsOnly,
                  child: Text('mDNS Only (LAN / Wi-Fi)', overflow: TextOverflow.ellipsis),
                ),
                DropdownMenuItem(
                  value: DiscoveryStrategy.bleOnly,
                  child: Text('BLE Only', overflow: TextOverflow.ellipsis),
                ),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _selectedStrategy = val);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SecurityMode>(
              initialValue: _securityMode,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Security Handshake',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: const [
                DropdownMenuItem(
                  value: SecurityMode.pinVerification,
                  child: Text('PIN / SAS Verification (Recommended)', overflow: TextOverflow.ellipsis),
                ),
                DropdownMenuItem(
                  value: SecurityMode.autoAccept,
                  child: Text('Auto-Accept (Insecure)', overflow: TextOverflow.ellipsis),
                ),
              ],
              onChanged: (val) {
                if (val != null) setState(() => _securityMode = val);
              },
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _nearbyService.isAdvertising
                          ? Colors.redAccent
                          : const Color(0xFF6366F1),
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    ),
                    icon: Icon(
                      _nearbyService.isAdvertising
                          ? Icons.stop
                          : Icons.cell_tower,
                      color: Colors.white,
                      size: 20,
                    ),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _nearbyService.isAdvertising ? 'Stop Advertising' : 'Start Advertising',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    onPressed: _toggleAdvertising,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _nearbyService.isDiscovering
                          ? Colors.orangeAccent
                          : const Color(0xFF10B981),
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    ),
                    icon: Icon(
                      _nearbyService.isDiscovering ? Icons.stop : Icons.radar,
                      color: Colors.white,
                      size: 20,
                    ),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _nearbyService.isDiscovering ? 'Stop Discovery' : 'Start Discovery',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    onPressed: _toggleDiscovery,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDiscoveredPeersCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Discovered Nearby Peers',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A36),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_discoveredPeers.length} Found',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_discoveredPeers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24.0),
                child: Center(
                  child: Text(
                    'No nearby peers discovered yet. Start discovery or advertising on other devices.',
                    style: TextStyle(color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _discoveredPeers.length,
                separatorBuilder: (_, _) => const Divider(color: Colors.white10),
                itemBuilder: (ctx, idx) {
                  final peer = _discoveredPeers[idx];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: const Color(0xFF6366F1),
                      child: Icon(
                        peer.discoveredVia == DiscoveryMedium.mdns
                            ? Icons.wifi
                            : (peer.discoveredVia == DiscoveryMedium.ble
                                ? Icons.bluetooth
                                : Icons.devices),
                        color: Colors.white,
                      ),
                    ),
                    title: Text(
                      peer.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      'Via: ${peer.discoveredVia.name.toUpperCase()}${peer.ipAddress != null ? ' | IP: ${peer.ipAddress}' : ''}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: _buildPeerTrailingAction(peer),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerTrailingAction(Peer peer) {
    final isPending = _pendingConnections.containsKey(peer.id);
    if (!isPending) {
      return ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6366F1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
        onPressed: () => _connectToPeer(peer),
        child: const Text('Connect', style: TextStyle(color: Colors.white)),
      );
    }

    final pin = _pendingConnections[peer.id];
    if (pin != null) {
      // Authenticating / Waiting for user to verify PIN on remote peer
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1B4B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF6366F1)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF10B981),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'PIN: $pin',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xFF10B981),
                fontSize: 13,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      );
    }

    // Initial connecting / negotiating handshake
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF374151),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      onPressed: null,
      icon: const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.white70,
        ),
      ),
      label: const Text(
        'Connecting...',
        style: TextStyle(color: Colors.white70, fontSize: 13),
      ),
    );
  }

  Future<void> _disconnectPeer(Peer peer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2E),
        title: const Text('Disconnect Peer'),
        content: Text('Are you sure you want to disconnect from ${peer.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Disconnect', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _nearbyService.disconnect(peer.id, reason: 'Disconnected by user');
      if (mounted) {
        setState(() {
          if (_selectedPeerId == peer.id) {
            final remaining =
                _nearbyService.connectedPeers.where((p) => p.id != peer.id).toList();
            _selectedPeerId = remaining.isNotEmpty ? remaining.first.id : null;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Disconnected from ${peer.displayName}'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Widget _buildConnectedSessionCard(List<Peer> connectedPeers) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Connected Peers',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                if (connectedPeers.length > 1)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                    icon: const Icon(Icons.link_off, size: 16),
                    label: const Text('Disconnect All', style: TextStyle(fontSize: 12)),
                    onPressed: () async {
                      await _nearbyService.disconnectAll(reason: 'Disconnected all peers');
                      if (mounted) {
                        setState(() {
                          _selectedPeerId = null;
                        });
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: connectedPeers.map((p) {
                final isSelected = p.id == _selectedPeerId;
                return InputChip(
                  avatar: Icon(
                    p.discoveredVia == DiscoveryMedium.mdns
                        ? Icons.wifi
                        : (p.discoveredVia == DiscoveryMedium.ble
                            ? Icons.bluetooth
                            : Icons.devices),
                    size: 16,
                    color: isSelected ? Colors.white : Colors.grey,
                  ),
                  label: Text(
                    p.displayName,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: const Color(0xFF6366F1),
                  backgroundColor: const Color(0xFF282A36),
                  onSelected: (selected) {
                    if (selected) setState(() => _selectedPeerId = p.id);
                  },
                  deleteIcon: const Icon(Icons.close, size: 16, color: Colors.white70),
                  deleteButtonTooltipMessage: 'Disconnect',
                  onDeleted: () => _disconnectPeer(p),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataTransferCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Data Transfer Workspace',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // Active Progress Indicators
            if (_activeTransfers.isNotEmpty) ...[
              ..._activeTransfers.values.map((u) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              'Payload #${u.payloadId} (${u.status.name})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${u.percentage}% (${u.bytesTransferred}/${u.totalBytes} B)',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: u.progress,
                        backgroundColor: Colors.white10,
                        color: const Color(0xFF10B981),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(color: Colors.white10),
            ],

            // Action Buttons for File and Stream
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                    ),
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Send 256KB File'),
                    ),
                    onPressed: _sendSampleFile,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                    ),
                    icon: Icon(
                      _activeSensorStream != null ? Icons.stop : Icons.sensors,
                      color: _activeSensorStream != null ? Colors.redAccent : Colors.white,
                      size: 18,
                    ),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(_activeSensorStream != null ? 'Stop Stream' : 'Live Stream'),
                    ),
                    onPressed: _toggleLiveStream,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Chat Message Box
            Container(
              height: 180,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF11111B),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                controller: _chatScrollController,
                itemCount: _chatMessages.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    _chatMessages[i],
                    style: TextStyle(
                      color: _chatMessages[i].startsWith('📤')
                          ? const Color(0xFF6366F1)
                          : const Color(0xFF10B981),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Message Input
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
