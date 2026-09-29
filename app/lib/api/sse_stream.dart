import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

/// Raised when no `: ping` comment or `data:` frame arrived within [wenxiangSseHeartbeatStaleAfter].
class SseHeartbeatStale implements Exception {
  @override
  String toString() => 'SSE heartbeat stale';
}

/// Keep in sync with [startSseHeartbeat] default in `server/src/sse.js`.
const wenxiangSseServerHeartbeatInterval = Duration(seconds: 5);

/// Treat the SSE body as dead after this long with no comment ping or `data:` frame.
const wenxiangSseHeartbeatStaleAfter = Duration(seconds: 18);

/// One SSE event block (lines joined by `\n`, terminated by `\n\n` on the wire).
class WenxiangSseFrame {
  WenxiangSseFrame._({
    this.event,
    this.isKeepaliveComment = false,
    this.isPingComment = false,
  });

  final ChatStreamEvent? event;
  final bool isKeepaliveComment;
  final bool isPingComment;

  bool get isAliveSignal => event != null || isKeepaliveComment;

  /// Parses a block from the companion SSE writer (`openSse` / `: ping` comments).
  static WenxiangSseFrame parse(String raw) {
    if (raw.trim().isEmpty) return WenxiangSseFrame._();
    final lines = raw.split('\n');
    final hasData = lines.any((line) => line.startsWith('data:'));
    if (hasData) {
      return WenxiangSseFrame._(event: ChatStreamEvent.fromSse(raw));
    }
    var comment = false;
    var ping = false;
    for (final line in lines) {
      if (!line.startsWith(':')) continue;
      comment = true;
      final body = line.substring(1).trim();
      if (body == 'ping' || body.startsWith('ping')) ping = true;
    }
    return WenxiangSseFrame._(
      isKeepaliveComment: comment,
      isPingComment: ping,
    );
  }
}

class WenxiangSseBuffer {
  String _buffer = '';

  List<WenxiangSseFrame> push(String chunk) {
    _buffer += chunk;
    final parts = _buffer.split('\n\n');
    _buffer = parts.removeLast();
    return [for (final part in parts) WenxiangSseFrame.parse(part)];
  }

  WenxiangSseFrame? drain() {
    if (_buffer.trim().isEmpty) return null;
    final frame = WenxiangSseFrame.parse(_buffer);
    _buffer = '';
    return frame;
  }
}

/// Decode companion SSE, honouring `: ping` comment heartbeats for stale detection.
Stream<ChatStreamEvent> streamWenxiangSseEvents({
  required Stream<List<int>> byteStream,
  required http.Client client,
  required void Function() throwIfCancelled,
}) async* {
  final parser = WenxiangSseBuffer();
  var lastAlive = DateTime.now();
  var stale = false;
  final watch = Timer.periodic(const Duration(seconds: 2), (_) {
    if (DateTime.now().difference(lastAlive) > wenxiangSseHeartbeatStaleAfter) {
      stale = true;
      try {
        client.close();
      } catch (_) {}
    }
  });
  try {
    await for (final chunk in byteStream.transform(utf8.decoder)) {
      throwIfCancelled();
      if (stale) throw SseHeartbeatStale();
      for (final frame in parser.push(chunk)) {
        if (frame.isAliveSignal) lastAlive = DateTime.now();
        if (frame.event != null) yield frame.event!;
      }
    }
    if (stale) throw SseHeartbeatStale();
    final tail = parser.drain();
    if (tail != null) {
      if (tail.isAliveSignal) lastAlive = DateTime.now();
      if (tail.event != null) yield tail.event!;
    }
  } finally {
    watch.cancel();
  }
}
