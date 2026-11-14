import 'dart:async';
import 'package:flutter/services.dart';

/// Continuous Android output; commands and drain checks have bounded waits.
class CallPcmPlayer {
  CallPcmPlayer({this.commandTimeout = const Duration(seconds: 3),
    this.stallTimeout = const Duration(seconds: 8)});

  static const channel = MethodChannel('cn.wenxiang.wenxiang/call_pcm');
  final Duration commandTimeout;
  final Duration stallTimeout;
  static int _nextToken = 0;
  String _token = '${++_nextToken}';
  Future<void>? _opening;
  Future<void> _tail = Future.value();
  int _pending = 0;
  int _rate = 0;
  final List<({int frame, void Function() callback})> _captions = [];

  Future<T?> _command<T>(String method, Map<String, Object> args) =>
      channel.invokeMethod<T>(method, args).timeout(commandTimeout);

  Future<void> push(Uint8List pcm, int rate, void Function()? onStart) {
    final token = _token;
    _pending++;
    final task = _tail.then((_) async {
      if (token != _token) return;
      if (_opening == null) {
        _rate = rate;
        _opening = _command<void>('open', {'token': token, 'rate': rate});
      }
      await _opening;
      if (token != _token) return;
      if (rate != _rate) throw StateError('PCM sample rate changed during playback');
      final frame = await _command<int>('push', {'token': token, 'pcm': pcm}) ?? 0;
      if (token == _token && onStart != null) _captions.add((frame: frame, callback: onStart));
    });
    _tail = task.catchError((Object _) {});
    return task.whenComplete(() { if (token == _token) _pending--; });
  }

  Future<void> waitForIdle() async {
    final token = _token;
    var lastHead = -1;
    final stalled = Stopwatch()..start();
    while (token == _token) {
      if (_opening == null && _pending == 0) return;
      await _tail.timeout(stallTimeout);
      if (token != _token) return;
      final status = await _command<Map<Object?, Object?>>('status', {'token': token});
      if (token != _token) return;
      final head = (status?['head'] as num?)?.toInt() ?? 0;
      while (_captions.isNotEmpty && _captions.first.frame <= head) {
        _captions.removeAt(0).callback();
      }
      if (head != lastHead) { lastHead = head; stalled.reset(); }
      if ((status?['remaining'] as num? ?? 0) == 0 && _pending == 0) return;
      if (stalled.elapsed >= stallTimeout) throw TimeoutException('PCM playback stalled');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> stop() async {
    final old = _token;
    _token = '${++_nextToken}';
    _opening = null;
    _pending = 0;
    _tail = Future.value();
    _captions.clear();
    await _command<void>('stop', {'token': old});
  }
}
