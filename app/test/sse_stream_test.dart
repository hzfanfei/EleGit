import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/sse_stream.dart';
import 'package:wenxiang/models.dart';

void main() {
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
    final frame = WenxiangSseFrame.parse('data: {"type":"status","phase":"generate"}\n');
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
