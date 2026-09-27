import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'adpcm.dart';

class VoiceEvent {
  VoiceEvent({
    required this.type,
    this.state,
    this.hint,
    this.code,
    this.role,
    this.text = '',
    this.finalCaption = false,
    this.engine,
    this.pcm,
    this.outputRate = 24000,
    this.detail,
  });

  final String type;
  final String? state;
  final String? hint;
  final String? code;
  final String? detail;
  final String? role;
  final String text;
  final bool finalCaption;
  final String? engine;
  final Uint8List? pcm;
  final int outputRate;

  factory VoiceEvent.fromJson(Map<String, dynamic> json) {
    return VoiceEvent(
      type: (json['type'] ?? '').toString(),
      state: json['state']?.toString(),
      hint: json['hint']?.toString(),
      code: json['code']?.toString(),
      role: json['role']?.toString(),
      text: (json['text'] ?? '').toString(),
      finalCaption: json['final'] == true,
      engine: json['engine']?.toString(),
      outputRate: (json['outputRate'] as num?)?.toInt() ?? 24000,
      detail: json['detail']?.toString(),
    );
  }
}

abstract class VoiceCallClient {
  Stream<VoiceEvent> connect();
  void hello({
    String owner = '',
    String repo = '',
    String? sessionId,
    String? bookId,
    String? chapter,
  });
  void sendPcm(Uint8List pcm);
  void barge();
  void played();
  void hangup();
}

class SocketVoiceClient implements VoiceCallClient {
  SocketVoiceClient(this.uri);

  final Uri uri;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  StreamController<VoiceEvent>? _events;

  /// The socket is stored before this returns. Callers send hello immediately
  /// after listen(); an async* body would still be pending and drop that hello.
  /// A tunnel that dies silently used to leave the call on 在说 or 思考中 forever.
  /// Without a pong within this long the socket closes and the call shows 通话断了.
  static const _pingInterval = Duration(seconds: 15);
  static const _connectTimeout = Duration(seconds: 15);

  @override
  Stream<VoiceEvent> connect() {
    final channel = IOWebSocketChannel.connect(
      uri,
      pingInterval: _pingInterval,
      connectTimeout: _connectTimeout,
    );
    _channel = channel;
    final events = StreamController<VoiceEvent>();
    _events = events;
    channel.ready.then((_) {
      if (!identical(_channel, channel) || events.isClosed) return;
      _socketSub = channel.stream.listen((message) {
        if (events.isClosed) return;
        if (message is List<int>) {
          final bytes = Uint8List.fromList(message);
          final adpcm = decodeAdpcm(bytes);
          events.add(adpcm == null
              ? VoiceEvent(type: 'pcm', pcm: bytes)
              : VoiceEvent(type: 'pcm', pcm: adpcm.pcm, outputRate: adpcm.sampleRate));
          return;
        }
        final decoded = jsonDecode(message.toString());
        if (decoded is Map) {
          events.add(VoiceEvent.fromJson(Map<String, dynamic>.from(decoded)));
        }
      }, onError: (Object err, StackTrace stack) {
        if (!events.isClosed) events.addError(err, stack);
      }, onDone: () {
        if (events.isClosed) return;
        final code = channel.closeCode;
        final reason = (channel.closeReason ?? '').trim();
        if (code != null || reason.isNotEmpty) {
          final parts = [
            'WebSocket closed',
            if (code != null) 'code=$code',
            if (reason.isNotEmpty) 'reason=$reason',
          ];
          events.addError(WebSocketChannelException(parts.join(' ')));
        }
        events.close();
      });
    }).catchError((Object err, StackTrace stack) {
      if (!events.isClosed) {
        events.addError(err, stack);
        events.close();
      }
    });
    return events.stream;
  }

  void _send(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  @override
  void hello({
    String owner = '',
    String repo = '',
    String? sessionId,
    String? bookId,
    String? chapter,
  }) {
    _send({
      'type': 'hello',
      'audio': 'adpcm',
      if (owner.isNotEmpty) 'owner': owner,
      if (repo.isNotEmpty) 'repo': repo,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
      if (bookId != null && bookId.isNotEmpty) 'bookId': bookId,
      if (chapter != null && chapter.isNotEmpty) 'chapter': chapter,
    });
  }

  @override
  void sendPcm(Uint8List pcm) {
    _channel?.sink.add(pcm);
  }

  @override
  void barge() {
    _send({'type': 'barge'});
  }

  @override
  void played() {
    _send({'type': 'played'});
  }

  @override
  void hangup() {
    _send({'type': 'hangup'});
    _socketSub?.cancel();
    _socketSub = null;
    _channel?.sink.close();
    _channel = null;
    final events = _events;
    _events = null;
    if (events != null && !events.isClosed) events.close();
  }
}

class FakeVoiceClient implements VoiceCallClient {
  FakeVoiceClient({this.events = const []});

  final List<VoiceEvent> events;
  final _out = StreamController<VoiceEvent>.broadcast();
  final List<Map<String, dynamic>> sent = [];
  int connectCalls = 0;
  int hangupCalls = 0;
  int bargeCalls = 0;
  int playedCalls = 0;

  void emit(VoiceEvent event) {
    _out.add(event);
  }

  void end() {
    if (!_out.isClosed) _out.addError(StateError('socket closed'));
  }

  @override
  Stream<VoiceEvent> connect() {
    connectCalls += 1;
    return Stream<VoiceEvent>.multi((listener) {
      for (final event in events) {
        listener.add(event);
      }
      final sub = _out.stream.listen(listener.add, onError: listener.addError, onDone: listener.close);
      listener
        ..onPause = sub.pause
        ..onResume = sub.resume
        ..onCancel = sub.cancel;
    });
  }

  @override
  void hello({
    String owner = '',
    String repo = '',
    String? sessionId,
    String? bookId,
    String? chapter,
  }) {
    sent.add({
      'type': 'hello',
      'owner': owner,
      'repo': repo,
      'sessionId': sessionId,
      if (bookId != null && bookId.isNotEmpty) 'bookId': bookId,
      if (chapter != null && chapter.isNotEmpty) 'chapter': chapter,
    });
  }

  @override
  void sendPcm(Uint8List pcm) {
    sent.add({'type': 'pcm', 'bytes': pcm.length});
  }

  @override
  void barge() {
    bargeCalls += 1;
    sent.add({'type': 'barge'});
  }

  @override
  void played() {
    playedCalls += 1;
    sent.add({'type': 'played'});
  }

  @override
  void hangup() {
    hangupCalls += 1;
    sent.add({'type': 'hangup'});
  }
}
