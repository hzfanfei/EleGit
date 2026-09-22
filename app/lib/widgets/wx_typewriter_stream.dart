import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

/// Buffers streamed text and reveals it on a steady cadence (Doubao-style).
class WxTypewriterStream {
  WxTypewriterStream({
    this.onReveal,
    this.tick = const Duration(milliseconds: 16),
  });

  final VoidCallback? onReveal;
  final Duration tick;

  final ValueNotifier<String> visible = ValueNotifier('');

  String _pending = '';
  int _shown = 0;
  Timer? _timer;
  bool _finishing = false;
  Completer<void>? _finishCompleter;
  DateTime? _finishUntil;

  String get fullText => _pending;

  bool get isIdle => _shown >= _pending.characters.length && _timer == null;

  void reset() {
    _stopTimer();
    _finishing = false;
    _finishCompleter = null;
    _finishUntil = null;
    _pending = '';
    _shown = 0;
    visible.value = '';
  }

  void push(String chunk) {
    if (chunk.isEmpty) return;
    final firstAfterIdle = _shown == 0 && _pending.isEmpty;
    _pending += chunk;
    if (firstAfterIdle) {
      final len = _pending.characters.length;
      final step = len <= 3 ? len : 3;
      _shown = step;
      visible.value = _pending.characters.take(_shown).toString();
      onReveal?.call();
    }
    _ensureTimer();
  }

  void replacePending(String text) {
    _pending = text;
    final len = _pending.characters.length;
    if (_shown > len) _shown = len;
    visible.value = _pending.characters.take(_shown).toString();
    _ensureTimer();
  }

  void flushNow() {
    _shown = _pending.characters.length;
    visible.value = _pending;
    _stopTimer();
    _finishing = false;
    _completeFinish();
  }

  Future<void> animateToEnd({Duration budget = const Duration(milliseconds: 360)}) async {
    if (_shown >= _pending.characters.length) return;
    _finishing = true;
    _finishUntil = DateTime.now().add(budget);
    _ensureTimer();
    final completer = Completer<void>();
    _finishCompleter = completer;
    return completer.future;
  }

  void dispose() {
    _stopTimer();
    visible.dispose();
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(tick, (_) => _onTick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  int get _pendingLen => _pending.characters.length;

  int _stepForLag(int lag) {
    if (lag <= 0) return 0;
    if (_finishing && _finishUntil != null) {
      final ms = _finishUntil!.difference(DateTime.now()).inMilliseconds;
      if (ms <= 0) return lag;
      final ticksLeft = (ms / tick.inMilliseconds).ceil().clamp(1, 48);
      return (lag / ticksLeft).ceil().clamp(1, lag);
    }
    if (lag > 160) return 10;
    if (lag > 64) return 5;
    if (lag > 20) return 2;
    return 1;
  }

  void _onTick() {
    final lag = _pendingLen - _shown;
    if (lag <= 0) {
      _stopTimer();
      _finishing = false;
      _completeFinish();
      return;
    }
    final step = _stepForLag(lag);
    _shown = (_shown + step).clamp(0, _pendingLen);
    visible.value = _pending.characters.take(_shown).toString();
    onReveal?.call();
  }

  void _completeFinish() {
    final c = _finishCompleter;
    _finishCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }
}
