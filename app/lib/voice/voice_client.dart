import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

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
  });

  final String type;
  final String? state;
  final String? hint;
  final String? code;
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
  @override
  Stream<VoiceEvent> connect() {
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    final events = StreamController<VoiceEvent>();
    _events = events;
    channel.ready.then((_) {
      if (!identical(_channel, channel) || events.isClosed) return;
      _socketSub = channel.stream.listen((message) {
        if (events.isClosed) return;
        if (message is List<int>) {
          events.add(VoiceEvent(type: 'pcm', pcm: Uint8List.fromList(message)));
          return;
        }
        final decoded = jsonDecode(message.toString());
        if (decoded is Map) {
          events.add(VoiceEvent.fromJson(Map<String, dynamic>.from(decoded)));
        }
      }, onError: (Object err, StackTrace stack) {
        if (!events.isClosed) events.addError(err, stack);
      }, onDone: () {
        if (!events.isClosed) events.close();
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

  @override
  Stream<VoiceEvent> connect() {
    connectCalls += 1;
    return Stream<VoiceEvent>.multi((listener) {
      for (final event in events) {
        listener.add(event);
      }
      final sub = _out.stream.listen(listener.add, onError: listener.addError);
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
