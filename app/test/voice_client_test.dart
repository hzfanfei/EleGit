import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/voice_client.dart';

void main() {
  test('hello sent right after listen still opens the call', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final got = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) {
        if (data is! String || got.isCompleted) return;
        got.complete(Map<String, dynamic>.from(jsonDecode(data) as Map));
        socket.add(jsonEncode({'type': 'state', 'state': 'listening'}));
      });
    });
    addTearDown(server.close);

    final client = SocketVoiceClient(Uri.parse('ws://127.0.0.1:${server.port}/v1/voice'));
    final states = <String>[];
    final sub = client.connect().listen((event) {
      if (event.state != null) states.add(event.state!);
    });
    client.hello(owner: 'hzfanfei', repo: 'EleGit');

    final msg = await got.future.timeout(const Duration(seconds: 3));
    expect(msg['type'], 'hello');
    expect(msg['owner'], 'hzfanfei');
    expect(msg['repo'], 'EleGit');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(states, contains('listening'));

    await sub.cancel();
    client.hangup();
  });

  test('a remote close keeps the close code', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      socket.close(1011, 'upstream dropped');
    });
    addTearDown(server.close);

    final client = SocketVoiceClient(Uri.parse('ws://127.0.0.1:${server.port}/v1/voice'));
    final done = Completer<Object>();
    final sub = client.connect().listen((_) {}, onError: (Object err) {
      if (!done.isCompleted) done.complete(err);
    });
    addTearDown(sub.cancel);

    final err = await done.future.timeout(const Duration(seconds: 3));
    expect(err.toString(), contains('code=1011'));
    expect(err.toString(), contains('upstream dropped'));
    client.hangup();
  });
}
