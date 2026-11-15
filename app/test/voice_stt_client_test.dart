import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/voice_stt_client.dart';

void main() {
  Future<SocketSttClient> serve(
    void Function(WebSocket, String) onMessage, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((data) {
        if (data is String) onMessage(socket, jsonDecode(data)['type'] as String);
      });
    });
    addTearDown(() async {
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    final client = SocketSttClient(
      Uri.parse('ws://127.0.0.1:${server.port}/v1/voice/stt'),
      recognitionTimeout: timeout,
    );
    addTearDown(client.dispose);
    return client;
  }

  test('remote close after stop emits an error instead of leaving STT waiting', () async {
    final client = await serve((socket, type) {
      if (type == 'stop') socket.close();
    });
    final result = client.connect().first;
    client.start();
    client.stop();
    final event = await result.timeout(const Duration(seconds: 3));
    expect(event.type, 'error');
    expect(event.code, 'network');
  });

  test('silent connection times out after stop', () async {
    final client = await serve((_, __) {}, timeout: const Duration(milliseconds: 150));
    final result = client.connect().first;
    client.start();
    client.stop();
    final event = await result.timeout(const Duration(seconds: 3));
    expect(event.type, 'error');
    expect(event.code, 'asr_timeout');
  });

  test('done followed by close does not report a spurious failure or timeout', () async {
    final client = await serve((socket, type) {
      if (type == 'stop') {
        socket.add(jsonEncode({'type': 'done', 'text': '测试语音'}));
        socket.close();
      }
    });
    final events = await (() async {
      final result = client.connect().toList();
      client.start();
      client.stop();
      return result.timeout(const Duration(seconds: 3));
    })();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(events.map((e) => e.type), ['done']);
    expect(events.single.text, '测试语音');
  });
}
