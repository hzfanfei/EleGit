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
        's1': [ChatMessage(role: 'user', content: '修一下', turnId: 't1')],
      },
    );

    final next = appendRepoTranscript(
      store,
      sessionId: 's1',
      question: '修一下',
      answer: '===TASK_COMPLETED===\n登录超时已修好。',
      turnId: 't1',
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
        turnId: 't1',
      ),
      isNull,
    );
  });

  test('a notice without a turn id is not written', () {
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
        's1': [ChatMessage(role: 'user', content: '修一下', turnId: 't1')],
      },
    );
    expect(
      appendRepoTranscript(
        store,
        sessionId: 's1',
        question: '修一下',
        answer: '不该挂上',
      ),
      isNull,
    );
  });

  test('the same question text on another turn does not take the previous answer', () {
    final messages = [
      ChatMessage(role: 'user', content: '同一句', turnId: 't1'),
      ChatMessage(role: 'assistant', content: '上一轮'),
      ChatMessage(role: 'user', content: '同一句', turnId: 't2'),
    ];
    expect(transcriptAnswersAsk(messages, 't2'), isFalse);
    expect(answerAfterTurn(messages, 't1'), '上一轮');
    expect(answerAfterTurn(messages, 't2'), isNull);

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
      transcripts: {'s1': messages},
    );
    final next = appendRepoTranscript(
      store,
      sessionId: 's1',
      question: '同一句',
      answer: '这一轮',
      turnId: 't2',
    );
    final saved = next!.transcripts['s1']!;
    expect(saved[1].content, '上一轮');
    expect(saved[3].content, '这一轮');
    expect(answerAfterTurn(saved, 't2'), '这一轮');
  });

  test('matches a held turn only by turn id', () {
    expect(
      heldTurnMatchesNotice(turnId: 't1', askedTurnId: 't1'),
      isTrue,
    );
    expect(
      heldTurnMatchesNotice(turnId: 't1', askedTurnId: 't2'),
      isFalse,
    );
    expect(
      heldTurnMatchesNotice(turnId: '', askedTurnId: 't1'),
      isFalse,
    );
    expect(
      heldTurnMatchesNotice(turnId: 't1', askedTurnId: ''),
      isFalse,
    );
    expect(
      pickHeldInboxItem(
        [
          {
            'answer': '上一轮',
            'question': '同一句',
            'turnId': 't1',
          },
        ],
        turnId: 't2',
      ),
      isNull,
    );
    expect(
      pickHeldInboxItem(
        [
          {
            'answer': '这一轮',
            'question': '同一句',
            'turnId': 't2',
          },
          {
            'answer': '上一轮',
            'question': '同一句',
            'turnId': 't1',
          },
        ],
        turnId: 't2',
      )?['answer'],
      '这一轮',
    );
  });
}
