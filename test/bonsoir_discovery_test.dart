import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/src/discovery/bonsoir_discovery.dart';

void main() {
  group('BonsoirDiscoveryService.formatServiceName', () {
    test(
      'preserves names that already fit, including the 63-byte boundary',
      () {
        expect(
          BonsoirDiscoveryService.formatServiceName('Camera', 'id'),
          'Camera-id',
        );
        final displayName = 'a' * 60;
        expect(
          BonsoirDiscoveryService.formatServiceName(displayName, 'id'),
          '$displayName-id',
        );
      },
    );

    test('fits Cinema Slate names while preserving the complete sender ID', () {
      final peerId = 'network_tc_${'a' * 32}';
      final name = BonsoirDiscoveryService.formatServiceName(
        'Test Device - Cinema Slate',
        peerId,
      );
      expect(utf8.encode(name), hasLength(63));
      expect(name, 'Test Device - Cinem-$peerId');
    });

    test('truncates at Unicode scalar boundaries using UTF-8 byte lengths', () {
      final peerId = 'network_tc_${'a' * 32}';
      for (final character in ['é', '界', '🎥']) {
        final name = BonsoirDiscoveryService.formatServiceName(
          character * 30,
          peerId,
        );
        final count = 19 ~/ utf8.encode(character).length;
        expect(name, '${character * count}-$peerId');
        expect(utf8.encode(name).length, lessThanOrEqualTo(63));
      }
    });

    test(
      'counts multibyte peer IDs and handles no room for a display name',
      () {
        final peerId = 'é' * 31;
        final name = BonsoirDiscoveryService.formatServiceName(
          'Camera',
          peerId,
        );
        expect(name, '-$peerId');
        expect(utf8.encode(name), hasLength(63));
      },
    );

    test(
      'uses stable distinct suffixes for oversized IDs with shared prefixes',
      () {
        final firstId = '${'a' * 100}1';
        final secondId = '${'a' * 100}2';
        final first = BonsoirDiscoveryService.formatServiceName(
          'Camera' * 20,
          firstId,
        );
        final second = BonsoirDiscoveryService.formatServiceName(
          'Camera' * 20,
          secondId,
        );
        expect(utf8.encode(first), hasLength(63));
        expect(utf8.encode(second), hasLength(63));
        expect(first, isNot(second));
        expect(
          BonsoirDiscoveryService.formatServiceName('Camera' * 20, firstId),
          first,
        );
      },
    );
  });

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
