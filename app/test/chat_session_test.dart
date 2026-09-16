import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';

void main() {
  test('ChatSession.fromJson reads id and title', () {
    final session = ChatSession.fromJson({
      'id': 'abc',
      'title': '这个仓库最近在做什么？',
      'createdAt': '2026-09-15T00:00:00.000Z',
      'updatedAt': '2026-09-15T00:00:00.000Z',
      'active': true,
    });
    expect(session.id, 'abc');
    expect(session.title, '这个仓库最近在做什么？');
    expect(session.active, isTrue);
  });

  test('ChatStreamEvent keeps sessionId from SSE JSON', () {
    final event = ChatStreamEvent.fromSse(
      'data: {"type":"done","engine":"acp","answer":"ok","sessionId":"s1"}',
    );
    expect(event?.type, 'done');
    expect(event?.sessionId, 's1');
    expect(event?.engine, 'acp');
  });
}
