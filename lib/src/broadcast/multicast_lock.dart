import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Manages Android `WifiManager.MulticastLock` via the native plugin channel.
///
/// UDP multicast packets are filtered out by default on Android Wi-Fi chips
/// unless a multicast lock is acquired. This helper reference-counts lock
/// acquisition so that listeners can share the lock safely.
class MulticastLock {
  MulticastLock._();

  static final MulticastLock instance = MulticastLock._();

  @visibleForTesting
  static const MethodChannel channel = MethodChannel('com.navideck.nearby');

  int _refCount = 0;
  Future<bool>? _pendingAcquire;

  @visibleForTesting
  int get refCount => _refCount;

  @visibleForTesting
  set refCount(int value) => _refCount = value;

  @visibleForTesting
  bool? isAndroidOverride;

  bool get _isAndroid {
    if (isAndroidOverride != null) return isAndroidOverride!;
    if (kIsWeb) return false;
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  /// Acquires the native Android MulticastLock if not already held.
  Future<bool> acquire() async {
    if (!_isAndroid) return false;

    if (_refCount > 0) {
      _refCount++;
      return true;
    }

    if (_pendingAcquire != null) {
      final success = await _pendingAcquire!;
      if (success) {
        _refCount++;
      }
      return success;
    }

    final completer = Completer<bool>();
    _pendingAcquire = completer.future;

    try {
      final result = await channel.invokeMethod<bool>('acquireMulticastLock');
      final success = result ?? false;
      if (success) {
        _refCount = 1;
      }
      completer.complete(success);
      return success;
    } on MissingPluginException {
      completer.complete(false);
      return false;
    } catch (e) {
      debugPrint('MulticastLock: failed to acquire lock: $e');
      completer.complete(false);
      return false;
    } finally {
      _pendingAcquire = null;
    }
  }

  /// Releases the native Android MulticastLock when all references are released.
  Future<bool> release() async {
    if (!_isAndroid) return false;

    if (_refCount > 0) {
      _refCount--;
      if (_refCount == 0) {
        try {
          final result = await channel.invokeMethod<bool>(
            'releaseMulticastLock',
          );
          return result ?? false;
        } on MissingPluginException {
          return false;
        } catch (e) {
          debugPrint('MulticastLock: failed to release lock: $e');
          return false;
        }
      }
    }
    return true;
  }
}
