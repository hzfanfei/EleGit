import 'dart:async';
import 'dart:math' as math;

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
  int _shownEnd = 0;
  int _lastClusterStart = 0;
  Iterator<String>? _remaining;
  int _remainingCount = 0;
  Timer? _timer;
  Completer<void>? _finishCompleter;
  DateTime? _finishUntil;

  String get fullText => _pending;

  bool get isIdle => _shownEnd == _pending.length && _timer == null;

  void reset() {
    _finish();
    _pending = '';
    _shown = 0;
    _shownEnd = 0;
    _lastClusterStart = 0;
    _remaining = null;
    visible.value = '';
  }

  void push(String chunk) {
    if (chunk.isEmpty) return;
    _pending += chunk;
    _remaining = null;
    _ensureTimer();
  }

  void replacePending(String text) {
    _pending = text;
    _setVisiblePrefix(text.characters.take(_shown));
    if (_shownEnd < text.length) {
      _ensureTimer();
    } else {
      _finish();
    }
  }

  void flushNow() {
    _setVisiblePrefix(_pending.characters);
    _finish();
  }

  Future<void> animateToEnd(
      {Duration budget = const Duration(milliseconds: 360)}) async {
    if (_shownEnd == _pending.length) return;
    final completer = _finishCompleter ??= Completer<void>();
    _finishUntil ??= DateTime.now().add(budget);
    _ensureTimer();
    return completer.future;
  }

  void dispose() {
    _finish();
    visible.dispose();
  }

  void _ensureTimer() {
    _timer ??= Timer.periodic(tick, (_) => _onTick());
  }

  void _finish() {
    _timer?.cancel();
    _timer = null;
    _finishUntil = null;
    _remaining = null;
    _finishCompleter?.complete();
    _finishCompleter = null;
  }

  void _setVisiblePrefix(Characters prefix) {
    _shown = prefix.length;
    _shownEnd = prefix.string.length;
    _lastClusterStart = _shownEnd - (prefix.isEmpty ? 0 : prefix.last.length);
    _remaining = null;
    visible.value = prefix.string;
  }

  void _prepareRemaining() {
    if (_remaining != null) return;
    // A later chunk can extend the last visible grapheme, e.g. a split emoji.
    final tail = _pending.substring(_lastClusterStart).characters;
    var remaining = tail.iterator;
    _remainingCount = tail.length;
    if (_shown > 0 && remaining.moveNext()) {
      if (_lastClusterStart + remaining.current.length == _shownEnd) {
        _remainingCount -= 1;
      } else {
        _shownEnd = _lastClusterStart;
        _shown -= 1;
        remaining = tail.iterator;
      }
    }
    _remaining = remaining;
  }

  int _stepForLag(int lag) {
    if (lag <= 0) return 0;
    final finishUntil = _finishUntil;
    if (finishUntil != null) {
      final remaining = finishUntil.difference(DateTime.now());
      if (remaining <= Duration.zero) return lag;
      final ticksLeft =
          (remaining.inMicroseconds / math.max(1, tick.inMicroseconds))
              .ceil()
              .clamp(1, 48);
      return (lag / ticksLeft).ceil().clamp(1, lag);
    }
    if (lag > 160) return 20;
    if (lag > 64) return 8;
    if (lag > 20) return 3;
    return 1;
  }

  void _onTick() {
    _prepareRemaining();
    final step = _stepForLag(_remainingCount);
    if (step == 0) {
      _finish();
      return;
    }
    final remaining = _remaining!;
    for (var i = 0; i < step && remaining.moveNext(); i++) {
      _lastClusterStart = _shownEnd;
      _shownEnd += remaining.current.length;
      _shown += 1;
      _remainingCount -= 1;
    }
    if (_remainingCount == 0) _finish();
    visible.value = _pending.substring(0, _shownEnd);
    onReveal?.call();
  }
}
