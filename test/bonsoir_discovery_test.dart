import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/src/discovery/bonsoir_discovery.dart';

void main() {
  group('BonsoirDiscoveryService.formatServiceType', () {
    test('returns fully-qualified _udp types as-is', () {
      expect(
        BonsoirDiscoveryService.formatServiceType('_navideck-tc._udp'),
        '_navideck-tc._udp',
      );
    });

    test('returns fully-qualified _tcp types as-is', () {
      expect(
        BonsoirDiscoveryService.formatServiceType('_navideck-tc._tcp'),
        '_navideck-tc._tcp',
      );
    });

    test('matches the protocol suffix case-insensitively', () {
      expect(
        BonsoirDiscoveryService.formatServiceType('_Navideck-TC._UDP'),
        '_Navideck-TC._UDP',
      );
      expect(
        BonsoirDiscoveryService.formatServiceType('_navideck-tc._TCP'),
        '_navideck-tc._TCP',
      );
    });

    test('returns fully-qualified types with an embedded _tcp label as-is', () {
      expect(
        BonsoirDiscoveryService.formatServiceType('_foo._tcp._sub._bar'),
        '_foo._tcp._sub._bar',
      );
    });

    test('expands plain short names to _tcp', () {
      expect(
        BonsoirDiscoveryService.formatServiceType('navideck-tc'),
        '_navideck-tc._tcp',
      );
    });

    test('defaults underscore-prefixed names without a protocol to _tcp', () {
      expect(
        BonsoirDiscoveryService.formatServiceType('_navideck-tc'),
        '_navideck-tc._tcp',
      );
    });

    test('expands names that merely contain a suffix token in their label', () {
      // "my_tcp_service" is a plain name, not a qualified type.
      expect(
        BonsoirDiscoveryService.formatServiceType('my_tcp_service'),
        '_my_tcp_service._tcp',
      );
    });
  });
}