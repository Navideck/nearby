import 'package:flutter_test/flutter_test.dart';
import 'package:nearby_example/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const NearbyExampleApp());
    expect(find.text('Nearby Cross-Platform Sync'), findsOneWidget);
  });
}
