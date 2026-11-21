import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/persist/chat_backfill.dart';

void main() {
  test('completion from a notice survives merging, copying and restoring history', () {
    final first = RepoChatStore(
      sessions: const [],
      activeId: 's1',
      transcripts: {
        's1': [
          ChatMessage(role: 'user', content: '问题', turnId: 't1'),
          ChatMessage(role: 'assistant', content: '完整答复。\n\n已核对。'),
        ],
      },
    );
    final updated = appendRepoTranscript(
      first,
      sessionId: 's1',
      turnId: 't1',
      answer: '===TASK_COMPLETED===已核对。',
    )!;
    final restored = RepoChatStore.fromJson(updated.toJson());
    final reply = restored.transcripts['s1']!.last;
    expect(reply.content, '完整答复。\n\n已核对。');
    expect(reply.taskCompleted, isTrue);
    expect(restored.transcripts['s1'], hasLength(2));
  });

  test('a final notice clears a timed-out turn even if its partial text matches', () {
    final question = ChatMessage(
      role: 'user',
      content: '问题',
      turnId: 't1',
      outcome: ChatTurnOutcome.timedOut,
    );
    final store = RepoChatStore(
      sessions: const [],
      activeId: 's1',
      transcripts: {
        's1': [question, ChatMessage(role: 'assistant', content: '已写好的答复')],
      },
    );
    final updated = appendRepoTranscript(
      store,
      sessionId: 's1',
      turnId: 't1',
      answer: '已写好的答复',
    );
    final saved = updated!.transcripts['s1']!;
    expect(saved.first.outcome, isNull);
    expect(saved, hasLength(2));
  });

  test('final paragraph prefixes merge in either delivery order', () {
    const full = '正在检查。\n\n正在打包。===TASK_COMPLETED===已去掉顶部卡片。\n\n下载 APK。';
    for (final fragment in ['已', '已去掉', '已去掉顶部卡片。']) {
      for (final answers in [[full, fragment], [fragment, full]]) {
        final messages = [ChatMessage(role: 'user', content: '修改', turnId: 't1')];
        insertTurnAnswer(messages, 0, answers[0]);
        insertTurnAnswer(messages, 0, answers[1]);
        expect(messages.length, 2);
        expect(messages.last.content, stripTaskMarker(full));
        expect(insertTurnAnswer(messages, 0, fragment), isFalse);
      }
    }
  });

  test('fragment cleanup keeps distinct replies, code examples and other turns', () {
    final messages = [
      ChatMessage(role: 'user', content: '修改', turnId: 't1'),
      ChatMessage(role: 'assistant', content: '正在打包。\n\n已移除卡片。\n\n下载 APK。'),
      ChatMessage(role: 'assistant', content: '已'),
      ChatMessage(role: 'assistant', content: '补充说明：保留触发线。'),
      ChatMessage(role: 'user', content: '确认', turnId: 't2'),
      ChatMessage(role: 'assistant', content: '已'),
    ];
    expect(insertTurnAnswer(messages, 0, '已'), isTrue);
    expect(messages.map((m) => m.content), [
      '修改', '正在打包。\n\n已移除卡片。\n\n下载 APK。',
      '补充说明：保留触发线。', '确认', '已',
    ]);
  });

  test('full stream and notification tail merge in either delivery order', () {
    const full = '正在打包。===TASK_COMPLETED===已支持组合多选。';
    const tail = '已支持组合多选。';
    for (final answers in [[full, tail], [tail, full]]) {
      final user = ChatMessage(role: 'user', content: '修复', turnId: 't1');
      final messages = [user];
      expect(insertTurnAnswer(messages, 0, answers[0]), isTrue);
      insertTurnAnswer(messages, 0, answers[1]);
      expect(messages.length, 2);
      expect(identical(messages.first, user), isTrue);
      expect(messages.last.content, '正在打包。\n\n$tail');
      expect(insertTurnAnswer(messages, 0, tail), isFalse);
    }
  });

  test('repairs existing duplicates without crossing a user turn', () {
    final messages = [
      ChatMessage(role: 'user', content: '修复', turnId: 't1'),
      ChatMessage(role: 'assistant', content: '正在检查。\n\n已完成。'),
      ChatMessage(role: 'assistant', content: '已完成。'),
      ChatMessage(role: 'user', content: '继续', turnId: 't2'),
      ChatMessage(role: 'assistant', content: '已完成。'),
    ];
    expect(insertTurnAnswer(messages, 0, '已完成。'), isTrue);
    expect(messages.length, 4);
    expect(answerAfterTurn(messages, 't1'), '正在检查。\n\n已完成。');
    expect(answerAfterTurn(messages, 't2'), '已完成。');
  });
  test('marker cleanup handles progress and preserves examples', () {
    expect(stripTaskMarker('正在检查。\r\n\r\n  ===TASK_COMPLETED===已完成。'),
        '正在检查。\r\n\r\n已完成。');
    const code = '```text\n===TASK_COMPLETED===\n```';
    expect(stripTaskMarker(code), code);
    const inline = '标记示例：`===TASK_COMPLETED===`';
    expect(stripTaskMarker(inline), inline);
  });

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
