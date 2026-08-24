import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nearby/nearby.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('NearbyService initialization test', (WidgetTester tester) async {
    final service = NearbyService(
      localPeerId: 'integration_test_peer',
      localDisplayName: 'Test Device',
    );
    expect(service.localPeerId, 'integration_test_peer');
    expect(service.localDisplayName, 'Test Device');
    expect(service.isAdvertising, isFalse);
    expect(service.isDiscovering, isFalse);
  });
}
