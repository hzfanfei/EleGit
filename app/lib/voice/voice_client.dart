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
  void hello({required String owner, required String repo, String? sessionId});
  void sendPcm(Uint8List pcm);
  void barge();
  void hangup();
}

class SocketVoiceClient implements VoiceCallClient {
  SocketVoiceClient(this.uri);

  final Uri uri;
  WebSocketChannel? _channel;

  @override
  Stream<VoiceEvent> connect() async* {
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    await channel.ready;
    await for (final message in channel.stream) {
      if (message is List<int>) {
        yield VoiceEvent(type: 'pcm', pcm: Uint8List.fromList(message));
      } else {
        final decoded = jsonDecode(message.toString());
        if (decoded is Map<String, dynamic>) {
          yield VoiceEvent.fromJson(decoded);
        }
      }
    }
  }

  void _send(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  @override
  void hello({required String owner, required String repo, String? sessionId}) {
    _send({
      'type': 'hello',
      'owner': owner,
      'repo': repo,
      if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
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
  void hangup() {
    _send({'type': 'hangup'});
    _channel?.sink.close();
    _channel = null;
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
  void hello({required String owner, required String repo, String? sessionId}) {
    sent.add({'type': 'hello', 'owner': owner, 'repo': repo, 'sessionId': sessionId});
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
  void hangup() {
    hangupCalls += 1;
    sent.add({'type': 'hangup'});
  }
}
