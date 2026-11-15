import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
// ignore: depend_on_referenced_packages
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:wenxiang/persist/chat_backfill.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/chat/running_sessions.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/chat_page.dart';
import 'package:wenxiang/screens/shell_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

class ControlledApi extends FakeWenxiangApi {
  final streams = <String, StreamController<ChatStreamEvent>>{};
  final histories = <String, List<ChatMessage>>{};
  final cancelled = <String>[];
  final cancelledTurns = <String?>[];

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
  void cancelChat({String? sessionId, String? turnId}) {
    cancelled.add(sessionId!);
    cancelledTurns.add(turnId);
  }

  void finish(String id, String answer) {
    streams[id]!
        .add(ChatStreamEvent(type: 'done', text: answer, engine: 'acp'));
    unawaited(streams[id]!.close());
  }
}

class UploadApi extends ControlledApi {
  final upload = Completer<ChatImageAttachment>();
  @override
  Future<ChatImageAttachment> uploadChatImage(
          {required Uint8List bytes, required String mimeType}) =>
      upload.future;
}

class TestImagePicker extends ImagePickerPlatform {
  @override
  Future<List<XFile>> getMultiImageWithOptions(
          {MultiImagePickerOptions options =
              const MultiImagePickerOptions()}) async =>
      [
        XFile.fromData(
            base64Decode(
                'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII='),
            mimeType: 'image/png',
            name: 'test.png'),
      ];
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

void expectRunningCount(int count) {
  final badge = find.byKey(const Key('wx-running-count'));
  if (count == 0) {
    expect(badge, findsNothing);
  } else {
    expect(find.descendant(of: badge, matching: find.text('$count')),
        findsOneWidget);
  }
}

void main() {
  tearDown(RunningSessions.stopAllForTesting);

  test(
      'late background notices merge before saving without replacing live messages',
      () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = ControlledApi();
    final repo = RunningSessions.of(api).repo(sampleRepo(), memory);
    final user =
        ChatMessage(role: 'user', content: 'question', turnId: 'late-turn');
    repo.transcripts['s1'] = [user];
    await repo.persist();
    await backfillChatFromNotice(
        sessionId: 's1',
        answer: 'late complete answer',
        owner: 'octo',
        repo: 'demo',
        turnId: 'late-turn');
    expect(identical(repo.transcripts['s1']!.first, user), isTrue);
    expect(repo.transcripts['s1']!.last.content, 'late complete answer');
    await repo.persist();
    expect(memory.loadChats('octo/demo').transcripts['s1']!.last.content,
        'late complete answer');
    repo.removeSession('s1');
    await repo.persist();
    expect(repo.transcripts.containsKey('s1'), isFalse);
    expect(
        memory.loadChats('octo/demo').transcripts.containsKey('s1'), isFalse);
  });

  for (final leave in [false, true]) {
    testWidgets('upload keeps its original session when leave=$leave',
        (tester) async {
      final picker = ImagePickerPlatform.instance;
      ImagePickerPlatform.instance = TestImagePicker();
      addTearDown(() => ImagePickerPlatform.instance = picker);
      final api = UploadApi();
      final pool = RunningSessions.of(api);
      await tester.pumpWidget(MaterialApp(
          theme: wenxiangTheme(),
          home: ChatPage(api: api, repo: sampleRepo(), onBack: () {})));
      await ready(tester);
      await tester.tap(find.byKey(const Key('wx-chat-attach')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('从相册选择'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(
          find.byKey(const Key('wx-chat-input')), 'original image question');
      await tester.tap(find.byKey(const Key('wx-chat-send')));
      await tester.pump();
      await menu(tester, '新建会话');
      final newId = pool.repo(sampleRepo(), null).activeId;
      expect(newId, isNot('s1'));
      await tester.enterText(
          find.byKey(const Key('wx-chat-input')), 'new draft');
      if (leave) await tester.pumpWidget(const SizedBox());
      api.upload.complete(
          const ChatImageAttachment(id: 'test-image', mimeType: 'image/png'));
      await tester.pump();
      expect(pool.execution('s1')!.current!.content, 'original image question');
      expect(pool.execution(newId), isNull);
      if (!leave) expect(find.text('new draft'), findsOneWidget);
      expect(pool.repo(sampleRepo(), null).transcripts[newId], isEmpty);
      pool.execution('s1')!.stop();
      expect(api.cancelledTurns.single, pool.execution('s1')!.current!.turnId);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('new session creates another session and both contexts keep running',
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
    expectRunningCount(0);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    expect(pool.active.length, 1);
    expectRunningCount(1);
    await menu(tester, '新建会话');
    expect(api.createSessionCalls, 1);
    expect(api.cancelled, isEmpty);
    expect(
        find.text('这个仓库最近在做什么？'), findsOneWidget); // New session suggestions.
    await tester.tap(find.text('README 里怎么写的？'));
    await tester.pump();
    expect(pool.active.length, 2);
    expectRunningCount(2);
    final second = pool.active.last.sessionId;
    expect(
        api.histories[second]!.any((m) => m.content.contains('最近在做')), isFalse);
    await menu(tester, '执行中');
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
    await menu(tester, '执行中');
    await tester.tap(find.descendant(
        of: find.byKey(ValueKey('wx-running-$second')),
        matching: find.byTooltip('中断')));
    await tester.pump();
    expect(api.cancelled, [second]);
    expect(pool.execution('s1')!.busy, isTrue);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('home count and open running list track additions and completions',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    final repo = pool.repo(sampleRepo(), memory);
    void start(String id) {
      final message = ChatMessage(role: 'user', content: id, turnId: id);
      repo.transcripts[id] = [message];
      pool.session(repo, id, false).enqueue(message);
    }

    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: ShellPage(api: api, memory: memory)));
    await ready(tester);
    expectRunningCount(0);
    start('first');
    await tester.pump();
    expectRunningCount(1);
    start('second');
    await tester.pump();
    expectRunningCount(2);
    api.finish('first', 'first answer');
    await tester.pumpAndSettle();
    expectRunningCount(1);
    await tester.tap(find.byKey(const Key('wx-home-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('执行中'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wx-running-first')), findsNothing);
    expect(find.byKey(const ValueKey('wx-running-second')), findsOneWidget);
    start('third');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wx-running-third')), findsOneWidget);
    expect(find.byKey(const ValueKey('wx-running-second')), findsOneWidget);
    api.finish('second', 'second answer');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wx-running-second')), findsNothing);
    expect(find.byKey(const ValueKey('wx-running-third')), findsOneWidget);
    api.finish('third', 'third answer');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('wx-running-third')), findsNothing);
    expect(find.text('暂无执行中的会话'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectRunningCount(0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final systemBack in [false, true]) {
    testWidgets('leaving running chat without prompt, systemBack=$systemBack',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final memory = AppMemory(await SharedPreferences.getInstance());
      final api = ControlledApi();
      final pool = RunningSessions.of(api);
      await tester.pumpWidget(MaterialApp(
          theme: wenxiangTheme(),
          home: ShellPage(api: api, memory: memory)));
      await ready(tester);
      await tester.tap(find.text('demo').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('这个仓库最近在做什么？'));
      await tester.pump();
      expect(pool.active.single.sessionId, 's1');
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('返回仓库'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('搜索仓库名'), findsOneWidget);
      expect(api.cancelled, isEmpty);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行中'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('wx-running-s1')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('搜索仓库名'), findsOneWidget);
      expect(pool.active.single.sessionId, 's1');
      expect(api.cancelled, isEmpty);
      api.finish('s1', '离开后仍然完成');
      await tester.pumpAndSettle();
      expect(pool.active, isEmpty);
      expect(memory.loadChats('octo/demo').transcripts['s1']!.last.content,
          '离开后仍然完成');
      await tester.pumpWidget(const SizedBox());
    });
  }

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
    await menu(tester, '执行中');
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
