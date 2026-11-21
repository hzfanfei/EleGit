import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';

void main() {
  test('health and API requests actually send authentication and tunnel headers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = <String>[];
    server.listen((request) async {
      expect(request.headers.value('X-Wenxiang-Key'), 'test-key');
      expect(request.headers.value('ngrok-skip-browser-warning'), 'true');
      received.add(request.uri.toString());
      request.response.headers.contentType = ContentType.json;
      request.response.write('{}');
      await request.response.close();
    });
    final api = WenxiangApi(baseUrl: 'http://127.0.0.1:${server.port}', apiKey: 'test-key');
    expect((await api.probeHealth()).ok, isTrue);
    await api.ping();
    await api.status();
    await api.checkoutStatus('octo', 'demo', fetchRemote: false);
    await api.checkoutStatus('octo', 'demo');
    expect(received, [
      '/health',
      '/health',
      '/v1/status',
      '/v1/repos/octo/demo/checkout-status?fetch=0',
      '/v1/repos/octo/demo/checkout-status',
    ]);
  });

  test('HTTP headers include API key and ngrok skip warning', () {
    final api = WenxiangApi(
      baseUrl: 'https://nonstrategically-pulverable-libby.ngrok-free.dev',
      apiKey: 'test-key',
    );
    expect(api.headers['X-Wenxiang-Key'], 'test-key');
    expect(api.headers['ngrok-skip-browser-warning'], 'true');
    expect(api.voiceUri().path, '/v1/voice');
    expect(api.voiceUri().scheme, 'wss');
    expect(api.voiceUri().queryParameters['key'], 'test-key');
    expect(api.voiceUri().queryParameters['ngrok-skip-browser-warning'], 'true');
  });
}
