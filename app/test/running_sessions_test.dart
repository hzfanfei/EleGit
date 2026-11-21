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
import 'package:wenxiang/screens/running_sessions_page.dart';
import 'package:wenxiang/copy/running_status.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

class ControlledApi extends FakeWenxiangApi {
  final streams = <String, StreamController<ChatStreamEvent>>{};
  final histories = <String, List<ChatMessage>>{};
  final attachments = <String, List<ChatImageAttachment>>{};
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
    attachments[sessionId] = List.of(images);
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
  expect(find.byKey(const Key('wx-running-float')), findsNothing);
  final badge = find.byKey(const Key('wx-running-count'));
  if (count == 0) {
    expect(badge, findsNothing);
  } else {
    expect(find.descendant(of: badge, matching: find.text('$count')),
        findsOneWidget);
  }
}

Future<void> openRunning(WidgetTester tester) async {
  final chatMore = find.byKey(const Key('wx-chat-more'));
  await tester.tap(chatMore.evaluate().isEmpty
      ? find.byKey(const Key('wx-home-more'))
      : chatMore.last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text('执行中').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void main() {
  tearDown(RunningSessions.stopAllForTesting);

  testWidgets(
      'live reply and error stay with their question ahead of the queue',
      (tester) async {
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    final repo = pool.repo(sampleRepo(), null);
    final question = ChatMessage(
      role: 'user',
      content: '最早的图片问题',
      turnId: 'original-turn',
      images: const [
        ChatImageAttachment(id: 'retry-image', mimeType: 'image/png')
      ],
    );
    repo.transcripts['s1'] = [question];
    pool.session(repo, 's1', false).enqueue(question);
    await tester.pumpWidget(MaterialApp(
      theme: wenxiangTheme(),
      home: ChatPage(api: api, repo: sampleRepo(), onBack: () {}),
    ));
    await ready(tester);

    final input = find.byKey(const Key('wx-chat-input'));
    await tester.enterText(input, '下一条排队问题');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await ready(tester);
    final replyTop =
        tester.getTopLeft(find.byKey(const Key('wx-live-reply'))).dy;
    expect(replyTop, greaterThan(tester.getTopLeft(find.text('最早的图片问题')).dy));
    expect(replyTop, lessThan(tester.getTopLeft(find.text('下一条排队问题')).dy));

    final first = api.streams['s1']!;
    first.add(ChatStreamEvent(type: 'error', error: '图片处理失败'));
    unawaited(first.close());
    await ready(tester);
    final messages = repo.transcripts['s1']!;
    expect(messages.map((m) => m.role), ['user', 'error', 'user']);
    expect(messages[1].turnId, question.turnId);

    api.finish('s1', '下一条已答完');
    await ready(tester);
    await tester.enterText(input, '正在写的草稿');
    await tester.pump();
    final retry = find.text('重试此问题');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await ready(tester);
    expect(api.histories['s1']!.last.content, question.content);
    expect(api.attachments['s1']!.single.id, 'retry-image');
    expect(find.text('正在写的草稿'), findsOneWidget);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'stopping keeps labelled partial replies and cancels queued turns',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    await tester.pumpWidget(MaterialApp(
      theme: wenxiangTheme(),
      home:
          ChatPage(api: api, repo: sampleRepo(), memory: memory, onBack: () {}),
    ));
    await ready(tester);
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await ready(tester);
    api.streams['s1']!.add(ChatStreamEvent(type: 'delta', text: '第一条的部分内容。'));
    await ready(tester);
    final input = find.byKey(const Key('wx-chat-input'));
    await tester.enterText(input, '排队但没有执行');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await ready(tester);
    await tester.tap(find.byTooltip('停止当前并取消排队'));
    await ready(tester);

    expect(find.text('已停止'), findsOneWidget);
    expect(find.text('已取消排队'), findsOneWidget);
    expect(find.text('问象 · 部分答复'), findsOneWidget);
    final saved = memory.loadChats('octo/demo').transcripts['s1']!;
    expect(saved.first.outcome, ChatTurnOutcome.stopped);
    expect(saved[1].content, '第一条的部分内容。');
    expect(saved.last.outcome, ChatTurnOutcome.queueCancelled);
    expect(api.histories['s1']!.length, 1);

    await tester.enterText(input, '停止后发出的新问题');
    await tester.pump();
    await tester.tap(find.byKey(const Key('wx-chat-send')));
    await ready(tester);
    expect(api.histories['s1']!.any((m) => m.content == '排队但没有执行'), isFalse);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'switching sessions restores each draft, attachments and scroll offset',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi();
    api.sessions
      ..clear()
      ..addAll([
        for (var i = 1; i <= 2; i++)
          ChatSession(
              id: 's$i',
              title: '会话 $i',
              createdAt: '',
              updatedAt: '',
              active: i == 1),
      ]);
    await memory.saveChats(
      'octo/demo',
      RepoChatStore(
        activeId: 's1',
        sessions: api.sessions,
        transcripts: {
          for (final session in api.sessions)
            session.id: [
              for (var i = 0; i < 30; i++)
                ChatMessage(role: 'user', content: '${session.id} 的历史问题 $i'),
            ],
        },
      ),
    );
    final picker = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = TestImagePicker();
    addTearDown(() => ImagePickerPlatform.instance = picker);
    await tester.pumpWidget(MaterialApp(
      theme: wenxiangTheme(),
      home:
          ChatPage(api: api, repo: sampleRepo(), memory: memory, onBack: () {}),
    ));
    await ready(tester);

    ScrollPosition position() => tester
        .state<ScrollableState>(find
            .descendant(
              of: find.byKey(const Key('wx-chat-list')),
              matching: find.byType(Scrollable),
            )
            .first)
        .position;

    Future<void> selectSession(String title) async {
      await menu(tester, '历史会话');
      await tester.tap(find.text(title).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    final input = find.byKey(const Key('wx-chat-input'));
    await tester.enterText(input, '会话一的草稿');
    await tester.tap(find.byKey(const Key('wx-chat-attach')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('从相册选择'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byTooltip('移除'), findsOneWidget);
    position().jumpTo(500);
    await ready(tester);

    await selectSession('会话 2');
    expect(find.text('会话一的草稿'), findsNothing);
    expect(find.byTooltip('移除'), findsNothing);
    expect(position().pixels, 0);
    await tester.enterText(input, '会话二的草稿');
    position().jumpTo(250);
    await ready(tester);

    await selectSession('会话 1');
    expect(find.text('会话一的草稿'), findsOneWidget);
    expect(find.byTooltip('移除'), findsOneWidget);
    expect(position().pixels, closeTo(500, 1));
    await selectSession('会话 2');
    expect(find.text('会话二的草稿'), findsOneWidget);
    expect(position().pixels, closeTo(250, 1));
  });

  testWidgets(
      'reply deltas notify the active reply without refreshing the pool',
      (tester) async {
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    final repo = pool.repo(sampleRepo(), null);
    final message = ChatMessage(role: 'user', content: '问题', turnId: 'turn');
    repo.transcripts['s1'] = [message];
    final task = pool.session(repo, 's1', false);
    task.enqueue(message);
    await tester.pump();

    var poolUpdates = 0;
    pool.addListener(() => poolUpdates += 1);
    final replies = <String>[];
    task.replyText.addListener(() => replies.add(task.replyText.value));
    api.streams['s1']!
      ..add(ChatStreamEvent(type: 'delta', text: '第一段'))
      ..add(ChatStreamEvent(type: 'delta', text: '。'));
    await tester.pump();
    expect(replies, ['第一段', '第一段。']);
    expect(poolUpdates, 0);

    api.finish('s1', '第一段。');
    await tester.pump();
    expect(poolUpdates, greaterThan(0));
    expect(repo.transcripts['s1']!.last.content, '第一段。');
  });

  test('running status uses only the newest block without thought or commands', () {
    expect(latestRunningActivity('思考·**旧的思考**\n旧的内容\n\n跑脚本\n'
        'powershell -command private-command · 已跑 8 秒'), '执行脚本 · 已跑 8 秒');
    expect(latestRunningActivity('跑脚本\n旧的输出\n\n思考·**新的思考**\n详细推理'),
        '正在思考');
    expect(latestRunningActivity('旧状态\r\n\r\n**正在读取文件**\r\n正文'),
        '正在读取文件');
    expect(latestRunningActivity('跑脚本\ncommand · 已跑 2 分 12 秒'),
        '执行脚本 · 已跑 2 分 12 秒');
    expect(latestRunningActivity('  '), isEmpty);
  });

  testWidgets('running rows keep equal fixed heights on narrow screens',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    final repo = pool.repo(sampleRepo(), null);
    for (final id in ['layout-first', 'layout-second']) {
      final message = ChatMessage(role: 'user',
          content: '$id 很长的会话标题\n继续描述一个很长的任务', turnId: id);
      repo.transcripts[id] = [message];
      pool.session(repo, id, false).enqueue(message);
    }
    await tester.pumpWidget(MaterialApp(
      theme: wenxiangTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)),
        child: child!,
      ),
      home: RunningSessionsPage(running: pool),
    ));
    await ready(tester);
    api.streams['layout-first']!.add(ChatStreamEvent(type: 'status',
        phase: 'activity', detail: '思考·**旧的思考**\n很多旧内容\n\n跑脚本\n'
        'powershell -command very-long-command · 已跑 8 秒'));
    await tester.pumpAndSettle();
    expect(find.text('执行脚本 · 已跑 8 秒'), findsOneWidget);
    expect(find.textContaining('旧的思考'), findsNothing);
    expect(find.textContaining('powershell'), findsNothing);
    final firstRow = find.byKey(const ValueKey('wx-running-layout-first'));
    final project = find.descendant(of: firstRow, matching: find.text('octo/demo'));
    final question = find.descendant(of: firstRow,
        matching: find.text('layout-first 很长的会话标题 继续描述一个很长的任务'));
    final status = find.descendant(of: firstRow,
        matching: find.text('执行脚本 · 已跑 8 秒'));
    for (final label in ['项目', '问题', '状态']) {
      expect(find.descendant(of: firstRow, matching: find.text(label)), findsOneWidget);
    }
    expect(tester.getTopLeft(project).dy, lessThan(tester.getTopLeft(question).dy));
    expect(tester.getTopLeft(question).dy, lessThan(tester.getTopLeft(status).dy));
    for (final id in ['layout-first', 'layout-second']) {
      expect(tester.getSize(find.byKey(ValueKey('wx-running-$id'))).height, 112);
    }
    api.streams['layout-first']!.add(ChatStreamEvent(type: 'status',
        phase: 'activity', detail: '旧的状态\n\n思考·下一步\n新的思考内容'));
    await tester.pumpAndSettle();
    expect(find.text('正在思考'), findsOneWidget);
    expect(find.text('执行脚本 · 已跑 8 秒'), findsNothing);
    expect(tester.getSize(find.byKey(const ValueKey('wx-running-layout-first')))
        .height, 112);
    final task = pool.execution('layout-first')!;
    task.holding = true;
    pool.changed();
    await tester.pump();
    expect(find.text('等待回复'), findsOneWidget);
    task.decision = ChatStreamEvent(type: 'ask');
    pool.changed();
    await tester.pump();
    expect(find.text('等待确认'), findsOneWidget);
    expect(tester.takeException(), isNull);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets('inbox tail stays out of the live row and merges after done',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = ControlledApi();
    final pool = RunningSessions.of(api);
    final repo = pool.repo(sampleRepo(), memory);
    final user = ChatMessage(role: 'user', content: '修复', turnId: 'live-turn');
    repo.transcripts['s1'] = [user];
    await repo.persist();
    final task = pool.session(repo, 's1', true);
    task.enqueue(user);
    await tester.pump();
    await backfillChatFromNotice(sessionId: 's1', answer: '已',
        owner: 'octo', repo: 'demo', turnId: 'live-turn');
    expect(repo.transcripts['s1'], [user]);
    expect(answerAfterTurn(memory.loadChats('octo/demo').transcripts['s1']!,
        'live-turn'), '已');
    api.finish('s1', '正在打包。===TASK_COMPLETED===已完成。');
    await tester.pumpAndSettle();
    expect(task.busy, isFalse);
    expect(repo.transcripts['s1']!.length, 2);
    expect(repo.transcripts['s1']!.last.content, '正在打包。\n\n已完成。');
    expect(memory.loadChats('octo/demo').transcripts['s1']!.length, 2);
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
      expect(find.text('正在上传图片…'), findsNothing);
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
    await tester.enterText(find.byKey(const Key('wx-chat-input')), '未发送草稿');
    await openRunning(tester);
    await tester.tap(find.byTooltip('关闭执行中'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('未发送草稿'), findsOneWidget);
    expectRunningCount(2);
    await openRunning(tester);
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
    await openRunning(tester);
    await tester.tap(find.descendant(
        of: find.byKey(ValueKey('wx-running-$second')),
        matching: find.byTooltip('中断')));
    await tester.pump();
    expect(api.cancelled, [second]);
    expect(pool.execution('s1')!.busy, isTrue);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('more menu count and open list track additions and completions',
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
    await openRunning(tester);
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
    testWidgets('chat exit confirms but running list closes directly, systemBack=$systemBack',
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
      await tester.enterText(find.byKey(const Key('wx-chat-input')), '保留草稿');
      await openRunning(tester);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('关闭执行中'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('保留草稿'), findsOneWidget);
      if (systemBack) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.byTooltip('返回仓库'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('wx-leave-chat')), findsOneWidget);
      expect(pool.active.single.sessionId, 's1');
      await tester.tap(find.byKey(const Key('wx-leave-chat-ok')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('搜索仓库名'), findsOneWidget);
      expect(api.cancelled, isEmpty);
      await openRunning(tester);
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
    await openRunning(tester);
    await tester.tap(find.byKey(const ValueKey('wx-running-other-session')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.text('octo/other'), findsOneWidget);
    expect(find.text('另一个项目的任务'), findsWidgets);
    expect(pool.active.length, 2);
    expect(api.cancelled, isEmpty);
    pool.stopAll();
    await tester.pumpWidget(const SizedBox());
  });
}
