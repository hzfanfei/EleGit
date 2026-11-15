import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/chat/running_sessions.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/chat_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

class ControlledApi extends FakeWenxiangApi {
  final streams = <String, StreamController<ChatStreamEvent>>{};
  final histories = <String, List<ChatMessage>>{};
  final cancelled = <String>[];

  @override
  Stream<ChatStreamEvent> chatStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    bool agentMode = false,
    String? turnId,
    List<ChatImageAttachment> images = const [],
  }) {
    histories[sessionId!] = List.of(history);
    final stream = StreamController<ChatStreamEvent>();
    streams[sessionId] = stream;
    return stream.stream;
  }

  @override
  void cancelChat({String? sessionId}) {
    cancelled.add(sessionId!);
  }

  void finish(String id, String answer) {
    streams[id]!
        .add(ChatStreamEvent(type: 'done', text: answer, engine: 'acp'));
    unawaited(streams[id]!.close());
  }
}

Future<void> ready(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> menu(WidgetTester tester, String text) async {
  await tester.tap(find.byKey(const Key('wx-chat-more')).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text(text).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  tearDown(RunningSessions.stopAllForTesting);

  testWidgets('minimize creates another session and both contexts keep running',
      (tester) async {
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        )));
    await ready(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    expect(pool.active.length, 1);
    await menu(tester, '最小化');
    expect(api.createSessionCalls, 1);
    expect(api.cancelled, isEmpty);
    expect(
        find.text('这个仓库最近在做什么？'), findsOneWidget); // New session suggestions.
    await tester.tap(find.text('README 里怎么写的？'));
    await tester.pump();
    expect(pool.active.length, 2);
    final second = pool.active.last.sessionId;
    expect(
        api.histories[second]!.any((m) => m.content.contains('最近在做')), isFalse);
    await menu(tester, '执行中会话');
    expect(find.byKey(const ValueKey('wx-running-s1')), findsOneWidget);
    expect(find.byKey(ValueKey('wx-running-$second')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('wx-running-s1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    api.streams['s1']!.add(ChatStreamEvent(type: 'delta', text: '第一会话仍在运行'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('第一会话'), findsWidgets);
    expect(api.cancelled, isEmpty);
    await menu(tester, '执行中会话');
    await tester.tap(find.descendant(
        of: find.byKey(ValueKey('wx-running-$second')),
        matching: find.byTooltip('中断')));
    await tester.pump();
    expect(api.cancelled, [second]);
    expect(pool.execution('s1')!.busy, isTrue);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving a project preserves the stream, queue and saved answer',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          memory: memory,
          onBack: () {},
        )));
    await ready(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('wx-chat-input')), '第二条排队');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(api.cancelled, isEmpty);
    api.finish('s1', '离开项目后完成第一条');
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(api.histories['s1']!.last.content, '第二条排队');
    expect(api.histories['s1']!.any((m) => m.content == '离开项目后完成第一条'), isTrue);
    api.finish('s1', '第二条也完成');
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(pool.active, isEmpty);
    expect(memory.loadChats('octo/demo').transcripts['s1']!.last.content,
        '第二条也完成');
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          memory: memory,
          initialSessionId: 's1',
          onBack: () {},
        )));
    await ready(tester);
    expect(find.textContaining('第二条也完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('running list switches across projects without stopping either',
      (tester) async {
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    final other = RepoItem.fromJson(
        {...sampleRepo().toJson(), 'name': 'other', 'fullName': 'octo/other'});
    final repo = pool.repo(other, null);
    final question =
        ChatMessage(role: 'user', content: '另一个项目的任务', turnId: 'other-turn');
    repo.transcripts['other-session'] = [question];
    pool.session(repo, 'other-session', false).enqueue(question);
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: api,
          repo: sampleRepo(),
          onBack: () {},
        )));
    await ready(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await menu(tester, '执行中会话');
    await tester.tap(find.byKey(const ValueKey('wx-running-other-session')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('octo/other'), findsOneWidget);
    expect(find.text('另一个项目的任务'), findsWidgets);
    expect(pool.active.length, 2);
    expect(api.cancelled, isEmpty);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });
}
