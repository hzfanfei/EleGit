import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/call_page.dart';
import 'package:wenxiang/screens/chat_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/voice/voice_client.dart';
import 'package:wenxiang/voice/voice_media.dart';

import 'support/fake_api.dart';

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
    expect(find.textContaining('有本机 Agent'), findsOneWidget);
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
    await tester.pump();
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();

    expect(find.textContaining('void main'), findsNothing);
    expect(find.textContaining('正在写'), findsOneWidget);
    expect(find.text('你问'), findsOneWidget);
    expect(find.text('问象'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 45));
    expect(find.textContaining('正在写'), findsOneWidget);
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
    await tester.pump();
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
    await tester.pump();

    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(find.byTooltip('历史会话'), findsOneWidget);
    expect(find.byKey(const Key('wx-call')), findsOneWidget);

    await tester.tap(find.byTooltip('新建会话'));
    await tester.pump();
    expect(find.textContaining('从进度问起'), findsOneWidget);

    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    expect(find.text('历史会话'), findsOneWidget);
    expect(find.text('新会话'), findsWidgets);

    await tester.tap(find.byTooltip('关闭会话').first);
    await tester.pump();
    expect(find.text('历史会话'), findsOneWidget);
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
    await tester.pump();
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();

    expect(find.textContaining('生成中'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '先记下下一问');
    expect(find.text('先记下下一问'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
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
    await tester.pump();
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();

    expect(find.byTooltip('停止'), findsOneWidget);
    await tester.tap(find.byTooltip('停止'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.byTooltip('发送'), findsOneWidget);
    expect(find.textContaining('正在写'), findsNothing);
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
  });

  testWidgets('call button opens the phone screen from chat', (tester) async {
    final media = FakeVoiceMedia();
    final client = FakeVoiceClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(voiceReady: true),
          repo: sampleRepo(),
          onBack: () {},
          voiceMedia: media,
          voiceClient: client,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-call')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CallPage), findsOneWidget);
    expect(find.text('开始通话'), findsOneWidget);
    expect(find.text('octo/demo'), findsWidgets);
  });
}
