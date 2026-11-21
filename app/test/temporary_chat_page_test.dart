import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/temporary_project_api.dart';
import 'package:wenxiang/chat/chat_image.dart';
import 'package:wenxiang/chat/running_sessions.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/screens/chat_page.dart';
import 'package:wenxiang/screens/temporary_chat_page.dart';
import 'support/fake_api.dart';

class TemporaryApi extends FakeWenxiangApi {
  TemporaryApi() : super(voiceReady: true, voiceCall: true);
  int created = 0;
  final closed = <String>[];
  final sent = <Map<String, dynamic>>[];
  final turns = <String, List<Map<String, dynamic>>>{};
  bool offline = false;
  Future<Map<String, dynamic>>? filesResponse;
  @override
  Future<String> createTemporaryChat() async {
    final id = 'temp-${++created}';
    turns[id] = [];
    return id;
  }

  @override
  Future<void> closeTemporaryChat(String id) async {
    closed.add(id);
    turns.remove(id);
  }

  @override
  Future<void> pingTemporaryChat(String id) async {}
  @override
  Future<void> stopTemporaryChat(String id) async {}
  @override
  Future<Map<String, dynamic>> temporaryChatRequest(String id,
      {String method = 'GET',
      String suffix = '',
      Map<String, dynamic>? body}) async {
    if (offline) throw Exception('offline');
    if (method == 'GET' && suffix.isEmpty && filesResponse != null) {
      return filesResponse!;
    }
    if (suffix == '/options') return {'ok': true};
    if (suffix == '/messages') {
      sent.add(body!);
      turns[id]!.add({
        'id': body['id'],
        'question': body['message'],
        'answer': '这是回答',
        'status': 'completed',
        'steps': []
      });
    }
    return {
      'version': 1,
      'busy': false,
      'turns': turns[id],
      'files': [],
      'downloadKey': 'key'
    };
  }
}

Future<void> pumpReady(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

void main() {
  tearDown(RunningSessions.stopAllForTesting);

  testWidgets('opens the generated files sheet while the data is pending',
      (tester) async {
    final response = Completer<Map<String, dynamic>>();
    final api = TemporaryApi()..filesResponse = response.future;
    await tester.pumpWidget(MaterialApp(
      home: TemporaryChatPage(api: api, onBack: () {}),
    ));
    await pumpReady(tester);
    await tester.tap(find.byTooltip('更多'));
    await pumpReady(tester);
    await tester.tap(find.text('本次生成文件'));
    await pumpReady(tester);

    expect(find.text('正在读取生成文件…'), findsOneWidget);
    response.complete({'files': []});
    await pumpReady(tester);
    expect(find.text('正在读取生成文件…'), findsNothing);
    expect(find.text('暂无生成文件'), findsOneWidget);
  });

  testWidgets('直接复用项目会话页，退出重开清空且不写正式项目', (tester) async {
    await tester.binding.setSurfaceSize(const Size(412, 892));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = TemporaryApi();
    var visible = true;
    late StateSetter update;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      update = setState;
      return visible
          ? TemporaryChatPage(
              api: api, onBack: () => setState(() => visible = false))
          : const Scaffold(body: Text('首页'));
    })));
    await pumpReady(tester);
    expect(find.byType(ChatPage), findsOneWidget);
    final page = tester.widget<ChatPage>(find.byType(ChatPage));
    expect(page.temporary, true);
    expect(page.memory, isNull);
    expect(find.text('从空白开始。'), findsOneWidget);
    expect(find.text('这个仓库最近在做什么？'), findsNothing);
    expect(find.byKey(const Key('wx-call')), findsOneWidget);
    expect(find.byKey(const Key('wx-agent-mode')), findsOneWidget);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await pumpReady(tester);
    expect(api.sent.single['message'], '你好');
    expect(api.sent.single['agentMode'], true);
    expect(find.text('这是回答'), findsOneWidget);
    expect(api.createSessionCalls, 0);
    expect(api.chatMessages, isEmpty);
    update(() => visible = false);
    await pumpReady(tester);
    expect(api.closed, ['temp-1']);
    update(() => visible = true);
    await pumpReady(tester);
    expect(api.created, 2);
    expect(find.text('这是回答'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await pumpReady(tester);
  });

  test('模型参数仅保存在临时项目，图像缓存和所有目录随退出清理', () async {
    final source = TemporaryApi();
    final api = TemporaryProjectApi(source);
    final a = await api.createSession('', '');
    final b = await api.createSession('', '');
    final data = await api.codexModels();
    expect(data['scopes']['repo']['model'], isNotNull);
    await api.setCodexModel('codex-test-a',
        scope: AskEngineScope.repo, effort: 'high', fast: true);
    expect(source.codexOptionsByScope['repo']?['codex-test-a'], isNull);
    expect(api.options(true)['effort'], 'high');
    expect(api.options(true)['fast'], true);
    final image = await api.uploadChatImage(
        bytes: Uint8List.fromList([1, 2]), mimeType: 'image/png');
    expect(ChatImageCache.get(image.id), isNotNull);
    await api.warmChatSession('', '', sessionId: a.id);
    expect(api.voiceUri().queryParameters['temporary'], a.id);
    await api.closeProject();
    expect(source.closed, containsAll([a.id, b.id]));
    expect(ChatImageCache.get(image.id), isNull);
  });

  test('复用标准流协议，优先使用归档链接并保留临时下载', () async {
    final source = TemporaryApi();
    final api = TemporaryProjectApi(source);
    final session = await api.createSession('', '');
    final stream = await api
        .chatStream(
            owner: '',
            repo: '',
            message: '测试',
            history: [ChatMessage(role: 'user', content: '测试')],
            sessionId: session.id,
            turnId: 't')
        .toList();
    expect(stream.last.type, 'done');
    expect(stream.last.text, '这是回答');
    final answer = api.linkFiles('[文件](outputs/a.txt)', session.id, {
      'files': [
        {'path': 'outputs/a.txt'}
      ],
      'downloadKey': 'local-token'
    });
    expect(
        answer,
        contains(
            '/temporary-files/${session.id}/outputs/a.txt?token=local-token'));
    expect(answer, isNot(contains(source.apiKey)));
    const onlineUrl = 'https://example.test/files/temporary-artifacts/a.txt?token=static-token';
    expect(api.linkFiles('[文件](outputs/a.txt)', session.id, {
      'files': [
        {'path': 'outputs/a.txt', 'downloadUrl': onlineUrl}
      ],
    }), '[文件]($onlineUrl)');
    await api.closeProject();
  });

  test('查询临时结果沿原始轮次找到后续答复', () async {
    final source = TemporaryApi();
    final api = TemporaryProjectApi(source);
    final session = await api.createSession('', '');
    source.turns[session.id]!.addAll([
      {'id': 'original', 'answer': '已列出计划', 'continuationId': 'continued'},
      {'id': 'continued', 'answer': '正在处理', 'status': 'running'},
      {'id': 'other', 'answer': '其他答复', 'status': 'completed'},
    ]);

    Future<String?> lookup() =>
        api.finalChatAnswer(sessionId: session.id, turnId: 'original');
    expect(await lookup(), isNull);
    source.turns[session.id]![1]
      ..['answer'] = '续接已完成'
      ..['status'] = 'completed';
    expect(await lookup(), '已列出计划\n\n续接已完成');
    await api.closeProject();
  });
}
