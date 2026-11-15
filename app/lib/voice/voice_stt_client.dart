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
  SocketSttClient(
    this.uri, {
    this.connectTimeout = const Duration(seconds: 10),
    this.recognitionTimeout = const Duration(seconds: 30),
  });

  final Uri uri;
  final Duration connectTimeout;
  final Duration recognitionTimeout;
  WebSocketChannel? _channel;
  StreamController<VoiceEvent>? _bridge;
  StreamSubscription? _sub;
  Timer? _deadline;
  bool _terminal = false;

  @override
  Stream<VoiceEvent> connect() {
    _terminal = false;
    final channel = WebSocketChannel.connect(uri);
    _channel = channel;
    final bridge = StreamController<VoiceEvent>.broadcast();
    _bridge = bridge;
    () async {
      try {
        await channel.ready.timeout(connectTimeout);
        if (_channel != channel || _terminal) return;
        _sub = channel.stream.listen((message) {
          if (_terminal || message is List<int>) return;
          try {
            final decoded = jsonDecode(message.toString());
            if (decoded is Map<String, dynamic>) {
              final event = VoiceEvent.fromJson(decoded);
              if (['done', 'error', 'cancelled'].contains(event.type)) {
                _terminal = true;
                _deadline?.cancel();
              }
              bridge.add(event);
            }
          } catch (_) {
            _fail('network');
          }
        }, onError: (Object err) {
          _fail('network');
        }, onDone: () {
          _fail('network');
          if (!bridge.isClosed) unawaited(bridge.close());
        });
      } catch (err) {
        if (_channel != channel) return;
        if (!_terminal) {
          _terminal = true;
          _deadline?.cancel();
          bridge.addError(err);
        }
        await bridge.close();
      }
    }();
    return _bridge!.stream;
  }

  void _fail(String code) {
    if (_terminal) return;
    _terminal = true;
    _deadline?.cancel();
    _bridge?.add(VoiceEvent(type: 'error', code: code));
    unawaited(_channel?.sink.close());
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
    if (_terminal || _channel == null) return;
    _deadline?.cancel();
    _deadline = Timer(recognitionTimeout, () => _fail('asr_timeout'));
    _send({'type': 'stop'});
  }

  @override
  void cancel() {
    _send({'type': 'cancel'});
    dispose();
  }

  @override
  void dispose() {
    _terminal = true;
    _deadline?.cancel();
    _deadline = null;
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
