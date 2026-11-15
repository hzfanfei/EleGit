import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';

void main() {
  test('real HTTP cancellation only closes the addressed session', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String, HttpResponse>{};
    final cancelled = <String>[];
    final cancelledTurns = <String?>[];
    final connected = Completer<void>();
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final id = body['sessionId'] as String;
      if (request.uri.path == '/v1/chat/cancel') {
        cancelled.add(id);
        cancelledTurns.add(body['turnId'] as String?);
        request.response.write('{}');
        await request.response.close();
        return;
      }
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.bufferOutput = false;
      requests[id] = request.response;
      request.response.write('data: {"type":"meta","sessionId":"$id"}\n\n');
      await request.response.flush();
      if (requests.length == 2 && !connected.isCompleted) connected.complete();
    });
    final api =
        WenxiangApi(baseUrl: 'http://127.0.0.1:${server.port}', apiKey: 'test');
    final answers = <String>[];
    final firstDone = Completer<void>();
    final firstSeen = Completer<void>();
    final secondSeen = Completer<void>();
    final firstErrors = <Object>[];
    final first = api
        .chatStream(
            owner: 'o',
            repo: 'r',
            message: 'one',
            history: [],
            sessionId: 'a',
            turnId: 'turn-a')
        .listen((_) {
      if (!firstSeen.isCompleted) firstSeen.complete();
    }, onError: (Object error) {
      firstErrors.add(error);
      if (!firstDone.isCompleted) firstDone.complete();
    }, onDone: () {
      if (!firstDone.isCompleted) firstDone.complete();
    });
    final done = Completer<void>();
    final second = api
        .chatStream(
            owner: 'o', repo: 'r', message: 'two', history: [], sessionId: 'b')
        .listen((event) {
      if (!secondSeen.isCompleted) secondSeen.complete();
      if (event.type == 'done') answers.add(event.text);
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    }, onError: (Object error) {
      if (!done.isCompleted) done.completeError(error);
    });
    try {
      await connected.future.timeout(const Duration(seconds: 5));
      await Future.wait([firstSeen.future, secondSeen.future])
          .timeout(const Duration(seconds: 5));
      api.cancelChat(sessionId: 'a');
      requests['b']!
          .write('data: {"type":"done","answer":"second completed"}\n\n');
      await requests['b']!.close();
      await done.future.timeout(const Duration(seconds: 5));
      await firstDone.future.timeout(const Duration(seconds: 5));
      expect(firstErrors, everyElement(isA<OperationCancelled>()));
      expect(answers, ['second completed']);
      // Allow the cancellation POST to finish before closing the test server.
      for (var i = 0; i < 20 && cancelled.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(cancelled, ['a']);
      expect(cancelledTurns, ['turn-a']);
    } finally {
      await server.close(force: true);
      await first.cancel();
      await second.cancel();
    }
  });
}
