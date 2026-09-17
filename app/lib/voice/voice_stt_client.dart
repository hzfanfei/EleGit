import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'voice_client.dart';

abstract class VoiceSttClient {
  Stream<VoiceEvent> connect();
  void start();
  void sendPcm(Uint8List pcm);
  void stop();
  void cancel();
  void dispose();
}

class SocketSttClient implements VoiceSttClient {
  SocketSttClient(this.uri);

  final Uri uri;
  WebSocketChannel? _channel;
  StreamController<VoiceEvent>? _bridge;
  StreamSubscription? _sub;

  @override
  Stream<VoiceEvent> connect() {
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    _bridge = StreamController<VoiceEvent>.broadcast();
    () async {
      try {
        await channel.ready;
        _sub = channel.stream.listen((message) {
          if (message is List<int>) return;
          final decoded = jsonDecode(message.toString());
          if (decoded is Map<String, dynamic>) {
            _bridge?.add(VoiceEvent.fromJson(decoded));
          }
        }, onError: _bridge?.addError, onDone: _bridge?.close);
      } catch (err) {
        _bridge?.addError(err);
        await _bridge?.close();
      }
    }();
    return _bridge!.stream;
  }

  void _send(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  @override
  void start() {
    _send({'type': 'start'});
  }

  @override
  void sendPcm(Uint8List pcm) {
    _channel?.sink.add(pcm);
  }

  @override
  void stop() {
    _send({'type': 'stop'});
  }

  @override
  void cancel() {
    _send({'type': 'cancel'});
    dispose();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _bridge?.close();
    _bridge = null;
  }
}

class FakeVoiceSttClient implements VoiceSttClient {
  FakeVoiceSttClient({this.doneText = '测试语音', this.delay = Duration.zero});

  final String doneText;
  final Duration delay;
  final _out = StreamController<VoiceEvent>.broadcast();
  StreamSubscription<Uint8List>? _mic;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;

  void attachMic(Stream<Uint8List> mic) {
    _mic = mic.listen((_) {});
  }

  @override
  Stream<VoiceEvent> connect() {
    return _out.stream;
  }

  @override
  void start() {
    startCalls += 1;
    _out.add(VoiceEvent(type: 'state', state: 'listening'));
  }

  @override
  void sendPcm(Uint8List pcm) {}

  @override
  void stop() {
    stopCalls += 1;
    Future<void>(() async {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      _out.add(VoiceEvent(type: 'done', text: doneText));
    });
  }

  @override
  void cancel() {
    cancelCalls += 1;
    _out.add(VoiceEvent(type: 'cancelled'));
  }

  @override
  void dispose() {
    _mic?.cancel();
    _out.close();
  }
}
