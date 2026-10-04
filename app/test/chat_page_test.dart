import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/chat_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_chrome.dart';
import 'package:wenxiang/voice/voice_client.dart';
import 'package:wenxiang/voice/voice_media.dart';
import 'package:wenxiang/voice/voice_stt_client.dart';

import 'support/fake_api.dart';

ScrollableState _chatScrollState(WidgetTester tester) {
  return tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const Key('wx-chat-list')),
      matching: find.byType(Scrollable),
    ).first,
  );
}

Future<void> _pumpUntilChatReady(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (find.text('正在准备对话…').evaluate().isEmpty) break;
  }
}

void main() {
  testWidgets('empty chat is a short prompt, not a chip wall', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('octo/demo'), findsWidgets);
    expect(find.textContaining('从进度问起'), findsOneWidget);
    expect(find.textContaining('连上本机问象'), findsOneWidget);
    expect(find.text('这个仓库最近在做什么？'), findsOneWidget);
    expect(find.text('README 里怎么写的？'), findsOneWidget);
    expect(find.textContaining('检出'), findsNothing);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text('▍'), findsNothing);
    expect(find.text('API Key'), findsNothing);
  });

  testWidgets('tokens appear progressively instead of dumping at the end', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(
            streamPace: const Duration(milliseconds: 40),
            streamEvents: [
              ChatStreamEvent(type: 'start', engine: 'local-progress'),
              ChatStreamEvent(type: 'delta', text: '## 最近\n'),
              ChatStreamEvent(type: 'delta', text: '- 修登录\n'),
              ChatStreamEvent(type: 'delta', text: '```\nvoid main() {'),
              ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
            ],
          ),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();

    expect(find.textContaining('void main'), findsNothing);
    expect(find.textContaining('正在连接'), findsOneWidget);
    expect(find.text('你问'), findsOneWidget);
    expect(find.text('问象'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 45));
    expect(find.textContaining('正在连接'), findsOneWidget);
    expect(find.text('最近'), findsNothing);

    await tester.pump(const Duration(milliseconds: 45));
    expect(find.text('最近'), findsOneWidget);
    expect(find.textContaining('void main'), findsNothing);
    expect(find.textContaining('##'), findsNothing);

    await tester.pump(const Duration(milliseconds: 45));
    expect(find.textContaining('修登录'), findsOneWidget);
    expect(find.textContaining('void main'), findsNothing);

    await tester.pump(const Duration(milliseconds: 45));
    expect(find.textContaining('void main'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);

    await tester.pump(const Duration(milliseconds: 45));
    await tester.pumpAndSettle();
    expect(find.text('你问'), findsOneWidget);
    expect(find.text('问象'), findsWidgets);
    expect(find.textContaining('void main'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('streaming reply appears without a block caret placeholder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('最近在修登录'), findsOneWidget);
    expect(find.text('▍'), findsNothing);
    expect(find.textContaining('本地进度'), findsWidgets);
    expect(find.text('你问'), findsOneWidget);
    expect(find.text('问象'), findsWidgets);
  });

  testWidgets('session start and history stay on the quiet chrome, not an AppBar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);

    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(const Key('wx-agent-mode')), findsOneWidget);
    expect(find.byTooltip('更多'), findsOneWidget);
    expect(find.byKey(const Key('wx-call')), findsNothing);
    expect(find.byKey(const Key('wx-voice-toggle')), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('wx-chat-new-session')).hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('从进度问起'), findsOneWidget);

    await tester.tap(find.byTooltip('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('wx-chat-history')).hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('wx-session-sheet')), findsOneWidget);
    expect(find.text('新会话'), findsWidgets);

    await tester.tap(find.byTooltip('关闭会话').first);
    await tester.pump();
    expect(find.byKey(const Key('wx-session-sheet')), findsOneWidget);
  });

  testWidgets('editing a sent user turn forks from there like AI chat', (tester) async {
    final api = FakeWenxiangApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('最近在修登录').evaluate().isNotEmpty) break;
    }

    expect(find.textContaining('最近在修登录'), findsOneWidget);
    expect(find.byTooltip('编辑'), findsOneWidget);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('wx-edit-field')), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('wx-edit-field')), 'README 里怎么写的？');
    await tester.tap(find.text('发送'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('README 说先跑').evaluate().isNotEmpty) break;
    }

    expect(find.text('README 里怎么写的？'), findsWidgets);
    expect(find.text('这个仓库最近在做什么？'), findsNothing);
    expect(find.textContaining('最近在修登录'), findsNothing);
    expect(find.textContaining('README 说先跑'), findsOneWidget);
    expect(api.lastChatMessage, 'README 里怎么写的？');
    expect(api.createSessionCalls, greaterThan(0));
    expect(api.lastSessionId, isNot('s1'));
  });

  testWidgets('progress hint is shown once before the answer starts', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(
            streamPace: const Duration(milliseconds: 200),
            streamEvents: [
              ChatStreamEvent(type: 'status', phase: 'activity', detail: '读·README.md'),
              ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
            ],
          ),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('读·README.md'), findsOneWidget);
    expect(find.byKey(const Key('wx-working-mark')), findsOneWidget);
    expect(find.byKey(const Key('wx-work-log')), findsOneWidget);
    expect(find.byKey(const Key('wx-work-toggle')), findsNothing);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('thought and tool lines share one fixed log', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(
            streamPace: const Duration(milliseconds: 200),
            streamEvents: [
              ChatStreamEvent(
                type: 'status',
                phase: 'activity',
                detail: '读·README.md\n\n改了登录页',
              ),
              ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
            ],
          ),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.textContaining('改了登录页'), findsOneWidget);
    expect(find.textContaining('读·README.md'), findsOneWidget);
    expect(find.text('展开'), findsNothing);
    expect(find.byKey(const Key('wx-work-log')), findsOneWidget);
    final box = tester.getSize(find.byKey(const Key('wx-work-log')));
    expect(box.height, 66);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('each progress row stays one line and shows the newest update', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(
            streamPace: const Duration(milliseconds: 1200),
            streamEvents: [
              ChatStreamEvent(type: 'status', phase: 'activity', detail: '终端·npm test'),
              ChatStreamEvent(
                type: 'status',
                phase: 'activity',
                detail: '终端·npm test\nnpm test\n12 passed',
              ),
              ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
            ],
          ),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));

    expect(find.text('终端·npm test'), findsOneWidget);
    expect(find.textContaining('12 passed'), findsNothing);
    expect(find.byKey(const Key('wx-work-age')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1秒'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('终端·npm test · 12 passed'), findsOneWidget);
    expect(find.text('1秒'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('hold poll applies partial inbox activity to the work log', (tester) async {
    const asked = '这个仓库最近在做什么？';
    final api = FakeWenxiangApi(
      streamEvents: [
        ChatStreamEvent(type: 'start', engine: 'local-progress', sessionId: 's-hold'),
        ChatStreamEvent(type: 'status', phase: 'activity', detail: '思考·旧进度'),
      ],
      inboxItems: [
        {
          'kind': 'agent-notification',
          'partial': true,
          'sessionId': 'relay-session',
          'question': asked,
          'activity': '读·inbox-hold.md',
          'answer': '',
          'createdAt': '2026-09-29T12:00:01.000Z',
        },
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text(asked));
    await tester.pump();
    await tester.pump();

    expect(find.text('思考·旧进度'), findsOneWidget);
    expect(find.textContaining('inbox-hold'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(find.textContaining('inbox-hold'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a quiet stream end enters hold like a transport drop', (tester) async {
    final api = FakeWenxiangApi(
      streamEvents: [
        ChatStreamEvent(type: 'start', engine: 'local-progress', sessionId: 's1'),
        ChatStreamEvent(type: 'status', phase: 'activity', detail: '思考·继续'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump();

    final mark = tester.widget<WxLoading>(find.byKey(const Key('wx-working-mark')));
    expect(mark.color, Wx.holdPoll);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a dropped answer waits without a retry button', (tester) async {
    final api = FakeWenxiangApi(
      streamThrows: AcceptedChatDrop(Exception('connection closed')),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('连接断了'), findsNothing);
    expect(find.text('重试上一问'), findsNothing);
    final mark = tester.widget<WxLoading>(find.byKey(const Key('wx-working-mark')));
    expect(mark.color, Wx.holdPoll);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('composer stays typable while a reply is streaming', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(streamDelay: const Duration(milliseconds: 80)),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();

    expect(find.text('可以先写下一条'), findsOneWidget);
    expect(find.byKey(const Key('wx-chat-input')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('wx-chat-input')), '先记下下一问');
    expect(find.text('先记下下一问'), findsOneWidget);
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('stop ends the waiting UI without a stack dump', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(streamDelay: const Duration(milliseconds: 80)),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();

    expect(find.byKey(const Key('wx-chat-stop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('wx-chat-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.byTooltip('发送'), findsOneWidget);
    expect(find.textContaining('正在连接'), findsNothing);
    expect(find.textContaining('生成回答'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
  });

  testWidgets('restored local transcript stays after server sessions reset', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    await memory.saveChats(
      'octo/demo',
      RepoChatStore(
        activeId: 'local-1',
        sessions: [
          ChatSession(
            id: 'local-1',
            title: '这个仓库最近在做什么？',
            createdAt: '2026-09-16T00:00:00Z',
            updatedAt: '2026-09-16T00:00:00Z',
            active: true,
          ),
        ],
        transcripts: {
          'local-1': [
            ChatMessage(role: 'user', content: '这个仓库最近在做什么？'),
            ChatMessage(role: 'assistant', content: '最近在修登录。', engine: 'local-progress'),
          ],
        },
      ),
    );
    final api = FakeWenxiangApi();
    api.sessions
      ..clear()
      ..add(
        ChatSession(
          id: 'server-new',
          title: '新会话',
          createdAt: '2026-09-16T01:00:00Z',
          updatedAt: '2026-09-16T01:00:00Z',
          active: true,
        ),
      );

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          memory: memory,
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('最近在修登录'), findsOneWidget);
    expect(find.text('你问'), findsOneWidget);
    expect(find.textContaining('从进度问起'), findsNothing);
    expect(find.byTooltip('复制回答'), findsOneWidget);
  });

  testWidgets('opens a restored repo chat at the latest message', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    await memory.saveChats(
      'octo/demo',
      RepoChatStore(
        activeId: 'local-1',
        sessions: [
          ChatSession(
            id: 'local-1',
            title: '长对话',
            createdAt: '2026-09-16T00:00:00Z',
            updatedAt: '2026-09-16T00:00:00Z',
            active: true,
          ),
        ],
        transcripts: {
          'local-1': [
            for (var i = 0; i < 24; i++) ...[
              ChatMessage(role: 'user', content: '早期问题 $i'),
              ChatMessage(role: 'assistant', content: '早期回答 $i'),
            ],
            ChatMessage(role: 'assistant', content: '最新回答在底部'),
          ],
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          memory: memory,
          onBack: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('最新回答在底部'), findsOneWidget);
    expect(find.text('早期问题 0'), findsNothing);
    expect(_chatScrollState(tester).position.pixels, lessThanOrEqualTo(1));
  });

  testWidgets('voice-ready chat hides call and shows hold-to-speak pad', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(voiceReady: true),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);

    expect(find.byKey(const Key('wx-call')), findsNothing);
    await tester.tap(find.byKey(const Key('wx-voice-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('按住 说话'), findsOneWidget);
    expect(find.byKey(const Key('wx-hold-speak')), findsOneWidget);
    expect(find.text('松手自动发送，上滑取消'), findsOneWidget);
  });

  testWidgets('phone button opens the call when the server allows it', (tester) async {
    final media = FakeVoiceMedia();
    final client = FakeVoiceClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(voiceReady: true, voiceCall: true),
          repo: sampleRepo(),
          onBack: () {},
          callMedia: media,
          callClient: client,
        ),
      ),
    );
    await _pumpUntilChatReady(tester);

    expect(find.byKey(const Key('wx-call')), findsOneWidget);
    await tester.tap(find.byKey(const Key('wx-call')));
    await tester.pump();
    await tester.pump();

    expect(find.text('在听'), findsOneWidget);
    expect(find.text('连接中'), findsNothing);
    expect(client.connectCalls, 1);
    expect(media.startCalls, 1);
  });

  testWidgets('repo chat reopens in the last voice input mode', (tester) async {
    SharedPreferences.setMockInitialValues({'wx.chatVoiceInput': true});
    final memory = AppMemory(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(voiceReady: true),
          repo: sampleRepo(),
          memory: memory,
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    expect(find.byKey(const Key('wx-hold-speak')), findsOneWidget);
    expect(find.byKey(const Key('wx-chat-input')), findsNothing);
  });

  testWidgets('a text question keeps the next turn on the keyboard', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(
            voiceReady: true,
            streamDelay: const Duration(milliseconds: 400),
          ),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.byKey(const Key('wx-voice-toggle')));
    await tester.pump();
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    expect(find.byKey(const Key('wx-chat-input')), findsOneWidget);
    expect(find.text('可以先写下一条，或按住说话'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wx-voice-toggle')));
    await tester.pump();
    expect(find.text('按住说下一条'), findsOneWidget);
    expect(find.byKey(const Key('wx-hold-speak')), findsOneWidget);

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('busy chat enqueues further sends and runs them in order', (tester) async {
    final api = FakeWenxiangApi(
      streamPace: const Duration(milliseconds: 80),
      streamEvents: [
        ChatStreamEvent(type: 'start', engine: 'local-progress'),
        ChatStreamEvent(type: 'delta', text: '第一条答完。'),
        ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    await tester.enterText(find.byType(TextField), '第二条任务');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await tester.pump();

    expect(find.text('第二条任务'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    expect(find.textContaining('还有 1 条排队'), findsOneWidget);
    expect(find.byKey(const Key('wx-chat-input')), findsOneWidget);
    expect(find.text('排队'), findsOneWidget);
    expect(api.chatMessages, ['这个仓库最近在做什么？']);

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (api.chatMessages.length >= 2) break;
    }
    expect(api.chatMessages, [
      '这个仓库最近在做什么？',
      '第二条任务',
    ]);
    expect(api.chatHistories.length, 2);
    expect(api.chatHistories.last.any((m) => m.role == 'assistant'), isTrue);
    expect(find.textContaining('第一条答完'), findsOneWidget);
    expect(find.text('排队中'), findsNothing);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('queued turn can be removed before it runs', (tester) async {
    final api = FakeWenxiangApi(
      streamPace: const Duration(milliseconds: 120),
      streamEvents: [
        ChatStreamEvent(type: 'start', engine: 'local-progress'),
        ChatStreamEvent(type: 'delta', text: '只答第一条。'),
        ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    await tester.enterText(find.byType(TextField), '不要这条');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await tester.pump();
    expect(find.text('不要这条'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wx-queue-remove')));
    await tester.pump();
    expect(find.text('不要这条'), findsNothing);
    expect(find.textContaining('还有'), findsNothing);

    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (api.chatMessages.length >= 1 &&
          find.textContaining('只答第一条').evaluate().isNotEmpty) {
        break;
      }
    }
    expect(api.chatMessages, ['这个仓库最近在做什么？']);
    expect(find.textContaining('只答第一条'), findsOneWidget);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });

  testWidgets('queued turn can be edited and still waits its turn', (tester) async {
    final api = FakeWenxiangApi(
      streamPace: const Duration(milliseconds: 200),
      streamEvents: [
        ChatStreamEvent(type: 'start', engine: 'local-progress'),
        ChatStreamEvent(type: 'delta', text: '按顺序答。'),
        ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: 's1'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await _pumpUntilChatReady(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    await tester.enterText(find.byType(TextField), '旧问题');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await tester.pump();
    expect(find.text('旧问题'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    final sessionsBefore = api.createSessionCalls;

    await tester.tap(find.byKey(const Key('wx-queue-edit')));
    await tester.pump();
    expect(find.byKey(const Key('wx-edit-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('wx-edit-field')), '改过的问题');
    await tester.tap(find.byKey(const Key('wx-queue-edit-save')));
    await tester.pump();

    expect(find.text('改过的问题'), findsOneWidget);
    expect(find.text('旧问题'), findsNothing);
    expect(find.text('排队中'), findsOneWidget);
    expect(api.chatMessages, ['这个仓库最近在做什么？']);
    expect(api.createSessionCalls, sessionsBefore);

    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (api.chatMessages.length >= 2) break;
    }
    expect(api.chatMessages, [
      '这个仓库最近在做什么？',
      '改过的问题',
    ]);
    expect(find.text('排队中'), findsNothing);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
