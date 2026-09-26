import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/persist/chat_backfill.dart';

void main() {
  test('appends the finished answer once and strips the marker', () {
    final store = RepoChatStore(
      sessions: [
        ChatSession(
          id: 's1',
          title: '新会话',
          createdAt: '2026-09-26T00:00:00Z',
          updatedAt: '2026-09-26T00:00:00Z',
          active: true,
        ),
      ],
      activeId: 's1',
      transcripts: {
        's1': [ChatMessage(role: 'user', content: '修一下')],
      },
    );

    final next = appendRepoTranscript(
      store,
      sessionId: 's1',
      question: '修一下',
      answer: '===TASK_COMPLETED===\n登录超时已修好。',
    );
    expect(next, isNotNull);
    expect(next!.transcripts['s1']!.length, 2);
    expect(next.transcripts['s1']!.last.content, '登录超时已修好。');

    expect(
      appendRepoTranscript(
        next,
        sessionId: 's1',
        question: '修一下',
        answer: '登录超时已修好。',
      ),
      isNull,
    );
  });
}
