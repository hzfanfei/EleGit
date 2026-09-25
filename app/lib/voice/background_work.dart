import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps the Android process in a foreground service while a voice turn,
/// chat stream, checkout, call, or playback queue is still running.
class BackgroundWork {
  static const _channel = MethodChannel('cn.wenxiang.wenxiang/background_work');
  static int _depth = 0;
  static int _micDepth = 0;
  static bool _started = false;
  static bool _micOn = false;
  static bool _starting = false;
  static Timer? _stop;

  static Future<void> acquire({bool microphone = false}) async {
    _depth += 1;
    if (microphone) _micDepth += 1;
    _stop?.cancel();
    _stop = null;
    await _ensureStarted();
  }

  static Future<void> release({bool microphone = false}) async {
    if (microphone && _micDepth > 0) _micDepth -= 1;
    if (_depth > 0) _depth -= 1;
    if (!Platform.isAndroid) return;
    if (_depth == 0) {
      if (_started) _scheduleStop();
      return;
    }
    if (_started && _micOn != (_micDepth > 0)) {
      await _ensureStarted();
    }
  }

  static Future<void> _ensureStarted() async {
    if (!Platform.isAndroid) return;
    final mic = _micDepth > 0;
    if (_started && _micOn == mic) return;
    if (_starting) return;
    _starting = true;
    try {
      await _channel.invokeMethod<void>('start', {'microphone': mic});
      _started = true;
      _micOn = mic;
    } catch (_) {
    } finally {
      _starting = false;
    }
    if (_started && _depth > 0 && _micOn != (_micDepth > 0)) {
      await _ensureStarted();
      return;
    }
    if (_started && _depth == 0) _scheduleStop();
  }

  static void _scheduleStop() {
    _stop?.cancel();
    _stop = Timer(const Duration(milliseconds: 2500), () {
      if (_depth > 0 || !_started) return;
      _started = false;
      _micOn = false;
      unawaited(_channel.invokeMethod<void>('stop').catchError((Object _) {}));
    });
  }
}
