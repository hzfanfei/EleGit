import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:wenxiang/api/sse_stream.dart';

class _ClosingClient extends MockClient {
  _ClosingClient(this.bytes) : super((_) async => throw UnimplementedError());
  final StreamController<List<int>> bytes;

  @override
  void close() {
    unawaited(bytes.close());
    super.close();
  }
}

void main() {
  test('quick voice times out even while heartbeats keep arriving', () async {
    final bytes = StreamController<List<int>>();
    final client = _ClosingClient(bytes);
    final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
      if (!bytes.isClosed) bytes.add(utf8.encode(': ping\n\n'));
    });
    final result = expectLater(
      streamQuickVoiceSseEvents(
        byteStream: bytes.stream,
        client: client,
        throwIfCancelled: () {},
        progressTimeout: const Duration(milliseconds: 100),
      ).toList(),
      throwsA(isA<VoiceReplyStalled>()),
    );
    bytes.add(utf8.encode('data: {"type":"caption","text":"最后一句"}\n\n'));
    await result.timeout(const Duration(seconds: 2));
    heartbeat.cancel();
    await bytes.close();
    client.close();
  });

  for (final terminal in ['done', 'error']) {
    test('quick voice exits on $terminal before HTTP closes', () async {
      final bytes = StreamController<List<int>>();
      final client = _ClosingClient(bytes);
      var ended = false;
      final result = streamQuickVoiceSseEvents(
        byteStream: bytes.stream,
        client: client,
        throwIfCancelled: () {},
      ).toList().then((events) {
        ended = true;
        expect(events.single.type, terminal);
      });
      bytes.add(utf8.encode('data: {"type":"$terminal"}\n\n'));
      await result.timeout(const Duration(seconds: 2));
      expect(ended, isTrue);
      await bytes.close();
      client.close();
    });
  }

  test('new audio resets quick voice progress deadline', () async {
    final bytes = StreamController<List<int>>();
    final client = _ClosingClient(bytes);
    final heartbeat = Timer.periodic(const Duration(milliseconds: 10), (_) {
      bytes.add(utf8.encode(': ping\n\n'));
    });
    final result = streamQuickVoiceSseEvents(
      byteStream: bytes.stream,
      client: client,
      throwIfCancelled: () {},
      progressTimeout: const Duration(milliseconds: 300),
    ).toList();
    for (var i = 0; i < 5; i++) {
      bytes.add(utf8.encode('data: {"type":"audio","pcm":"AAE="}\n\n'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    bytes.add(utf8.encode('data: {"type":"done"}\n\n'));
    expect(await result.timeout(const Duration(seconds: 2)), hasLength(6));
    heartbeat.cancel();
    await bytes.close();
    client.close();
  });

  test('quick voice reports EOF without a terminal event', () async {
    final client = MockClient((_) async => throw UnimplementedError());
    await expectLater(
      streamQuickVoiceSseEvents(
        byteStream: const Stream.empty(),
        client: client,
        throwIfCancelled: () {},
      ).toList(),
      throwsA(predicate((error) => error.toString().contains('连接已中断'))),
    );
    client.close();
  });

  test('recognizes server comment ping keepalive', () {
    final frame = WenxiangSseFrame.parse(': ping\n');
    expect(frame.isKeepaliveComment, isTrue);
    expect(frame.isPingComment, isTrue);
    expect(frame.event, isNull);
  });

  test('recognizes openSse anti-buffer pad as comment keepalive', () {
    final frame = WenxiangSseFrame.parse(': ${' ' * 32}\n');
    expect(frame.isKeepaliveComment, isTrue);
    expect(frame.isPingComment, isFalse);
    expect(frame.event, isNull);
  });

  test('parses data events and marks them alive', () {
    final frame =
        WenxiangSseFrame.parse('data: {"type":"status","phase":"generate"}\n');
    expect(frame.event?.type, 'status');
    expect(frame.isAliveSignal, isTrue);
  });

  test('buffer splits on blank line boundaries', () {
    final buf = WenxiangSseBuffer();
    final first = buf.push(': ping\n\n');
    expect(first, hasLength(1));
    expect(first.first.isPingComment, isTrue);
    final second = buf.push('data: {"type":"delta","text":"a"}\n\n');
    expect(second, hasLength(1));
    expect(second.first.event?.text, 'a');
  });
}
