import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Holds the Android process in a `dataSync` foreground service while the
/// user has local notifications enabled, so the WebSocket listener can keep
/// receiving inbox pushes (answer-completion, build, Claude Code task) when
/// the app is in the background.
///
/// Mirrors the API surface of `BackgroundWork` in `voice/background_work.dart`
/// but tracks a single boolean — local-notifications is a user-toggle, not a
/// ref-counted stream of voice turns.
class BackgroundSync {
  static const _channel = MethodChannel('cn.wenxiang.wenxiang/background_sync');
  static bool _started = false;

  static Future<void> acquire() async {
    if (!Platform.isAndroid) return;
    if (_started) return;
    try {
      await _channel.invokeMethod<void>('start');
      _started = true;
    } catch (_) {
      // best-effort; the WS retry path will keep notifications flowing even
      // if the service could not start.
    }
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) return;
    if (!_started) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
    } finally {
      _started = false;
    }
  }
}
