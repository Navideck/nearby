import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Nearby connected and broadcast APIs initialize', (
    WidgetTester tester,
  ) async {
    final service = NearbyService(
      localPeerId: 'integration_test_peer',
      localDisplayName: 'Test Device',
    );
    expect(service.localPeerId, 'integration_test_peer');
    expect(service.isAdvertising, isFalse);

    final channel = BroadcastChannel(
      config: const BroadcastChannelConfig(channelId: 'integration-test'),
      senderId: 'integration-test-peer',
    );
    expect(channel.senderId, 'integration-test-peer');
    expect(channel.isBroadcasting, isFalse);
    expect(channel.isListening, isFalse);
    await channel.dispose();
    await service.dispose();
  });
}
