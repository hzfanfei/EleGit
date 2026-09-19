import 'dart:io';

import 'package:flutter/services.dart';

/// Force Android back to media/music routing (Vivo etc. keep call mode after [record]).
class AndroidMediaAudio {
  static const _channel = MethodChannel('cn.wenxiang.wenxiang/audio_route');

  static Future<void> resetToMediaPlayback() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('resetToMediaPlayback');
    } catch (_) {
      // Tests / desktop stubs.
    }
  }
}
