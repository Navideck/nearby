import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nearby/src/broadcast/multicast_lock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final log = <MethodCall>[];
  var acquireResult = true;
  var releaseResult = true;
  var throwOnAcquire = false;

  setUp(() {
    log.clear();
    acquireResult = true;
    releaseResult = true;
    throwOnAcquire = false;
    MulticastLock.instance.refCount = 0;
    MulticastLock.instance.isAndroidOverride = true;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MulticastLock.channel, (
          MethodCall methodCall,
        ) async {
          log.add(methodCall);
          switch (methodCall.method) {
            case 'acquireMulticastLock':
              if (throwOnAcquire) {
                throw PlatformException(code: 'ERROR', message: 'Failed');
              }
              return acquireResult;
            case 'releaseMulticastLock':
              return releaseResult;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MulticastLock.channel, null);
    MulticastLock.instance.refCount = 0;
    MulticastLock.instance.isAndroidOverride = null;
  });

  test(
    'non-Android platform returns false and does not call channel',
    () async {
      MulticastLock.instance.isAndroidOverride = false;
      final acquired = await MulticastLock.instance.acquire();
      expect(acquired, isFalse);
      expect(MulticastLock.instance.refCount, 0);
      expect(log, isEmpty);

      final released = await MulticastLock.instance.release();
      expect(released, isFalse);
      expect(log, isEmpty);
    },
  );

  test(
    'single acquire and release cycle calls platform channel once each',
    () async {
      final acquired = await MulticastLock.instance.acquire();
      expect(acquired, isTrue);
      expect(MulticastLock.instance.refCount, 1);
      expect(log.map((m) => m.method), ['acquireMulticastLock']);

      final released = await MulticastLock.instance.release();
      expect(released, isTrue);
      expect(MulticastLock.instance.refCount, 0);
      expect(log.map((m) => m.method), [
        'acquireMulticastLock',
        'releaseMulticastLock',
      ]);
    },
  );

  test(
    'nested acquire and release maintains refCount and releases only on 0',
    () async {
      expect(await MulticastLock.instance.acquire(), isTrue);
      expect(MulticastLock.instance.refCount, 1);

      expect(await MulticastLock.instance.acquire(), isTrue);
      expect(MulticastLock.instance.refCount, 2);

      // Only one channel acquire call was made
      expect(log.map((m) => m.method), ['acquireMulticastLock']);

      expect(await MulticastLock.instance.release(), isTrue);
      expect(MulticastLock.instance.refCount, 1);
      expect(log.map((m) => m.method), ['acquireMulticastLock']);

      expect(await MulticastLock.instance.release(), isTrue);
      expect(MulticastLock.instance.refCount, 0);
      expect(log.map((m) => m.method), [
        'acquireMulticastLock',
        'releaseMulticastLock',
      ]);
    },
  );

  test(
    'failed acquire does not commit refCount and allows future retry',
    () async {
      acquireResult = false;
      final acquired = await MulticastLock.instance.acquire();
      expect(acquired, isFalse);
      expect(MulticastLock.instance.refCount, 0);

      // Subsequent retry with success succeeds
      acquireResult = true;
      final retryAcquired = await MulticastLock.instance.acquire();
      expect(retryAcquired, isTrue);
      expect(MulticastLock.instance.refCount, 1);
    },
  );

  test(
    'exception during acquire does not commit refCount and returns false',
    () async {
      throwOnAcquire = true;
      final acquired = await MulticastLock.instance.acquire();
      expect(acquired, isFalse);
      expect(MulticastLock.instance.refCount, 0);

      throwOnAcquire = false;
      final retryAcquired = await MulticastLock.instance.acquire();
      expect(retryAcquired, isTrue);
      expect(MulticastLock.instance.refCount, 1);
    },
  );

  test('concurrent acquire calls await the same in-flight future', () async {
    final completer = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MulticastLock.channel, (
          MethodCall methodCall,
        ) async {
          log.add(methodCall);
          return completer.future;
        });

    final future1 = MulticastLock.instance.acquire();
    final future2 = MulticastLock.instance.acquire();

    // Only one channel call dispatched while in-flight
    expect(log.length, 1);

    completer.complete(true);
    final results = await Future.wait([future1, future2]);
    expect(results, [true, true]);
    expect(MulticastLock.instance.refCount, 2);
  });
}
