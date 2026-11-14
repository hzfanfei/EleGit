import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/widgets/agent_details_dialog.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';
import 'package:wenxiang/models.dart';
import 'support/fake_api.dart';

class _Api extends FakeWenxiangApi {
  Completer<Map<String, dynamic>>? pending;
  bool fail = false;
  int speedCalls = 0;
  Completer<void>? savePending;
  int saveCalls = 0;
  @override
  Future<void> setCodexModel(String model,
      {required AskEngineScope scope,
      String? effort,
      bool? fast,
      bool select = true}) async {
    saveCalls++;
    if (savePending != null) await savePending!.future;
    await super.setCodexModel(model,
        scope: scope, effort: effort, fast: fast, select: select);
  }

  @override
  Future<Map<String, dynamic>> codexModels() async {
    if (fail) throw Exception('offline');
    return super.codexModels();
  }

  @override
  Future<Map<String, dynamic>> measureModelSpeed(AskEngineScope scope) {
    lastSpeedScope = scope;
    speedCalls++;
    return pending?.future ?? super.measureModelSpeed(scope);
  }
}

void main() {
  Future<void> choose(WidgetTester tester, String id) async {
    await tester.tap(find.text('切换模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('agent-model-$id')));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester, _Api api,
      {AskEngineScope scope = AskEngineScope.repo}) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => AgentDetailsDialog(
                            api: api, agentMode: true, scope: scope)),
                    child: const Text('打开'))))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows repository preferences and measures repository model',
      (tester) async {
    final api = _Api();
    api.codexModelsByScope['book'] = 'codex-test-b';
    api.codexOptionsByScope['repo'] = {
      'codex-test-a': {'effort': 'high', 'fast': true}
    };
    await open(tester, api);
    expect(find.text('当前模型：codex-test-a'), findsOneWidget);
    expect(find.text('思考强度：高'), findsOneWidget);
    expect(find.text('快速模式：开启'), findsOneWidget);
    await tester.tap(find.text('模型测速'));
    await tester.pumpAndSettle();
    expect(api.lastSpeedScope, AskEngineScope.repo);
    expect(find.textContaining('42.5 token/秒'), findsOneWidget);
    expect(find.textContaining('首字 0.25 秒'), findsOneWidget);
  });

  for (final scope in AskEngineScope.values) {
    testWidgets('switch and speed test only affect ${scope.name}',
        (tester) async {
      final api = _Api();
      final other = scope == AskEngineScope.book ? 'repo' : 'book';
      api.codexOptionsByScope[scope.name] = {
        'codex-test-b': {'effort': 'high', 'fast': true}
      };
      await open(tester, api, scope: scope);
      await choose(tester, 'codex-test-b');
      expect(api.lastCodexScope, scope.name);
      expect(api.codexModelsByScope[scope.name], 'codex-test-b');
      expect(api.codexModelsByScope[other], 'codex-test-a');
      expect(find.text('当前模型：codex-test-b'), findsOneWidget);
      expect(find.text('思考强度：高'), findsOneWidget);
      await tester.ensureVisible(find.text('模型测速'));
      await tester.tap(find.text('模型测速'));
      await tester.pumpAndSettle();
      expect(api.lastSpeedScope, scope);
      await tester.ensureVisible(find.text('切换模型'));
      await choose(tester, 'codex-test-a');
      expect(find.textContaining('42.5 token/秒'), findsNothing);
    });
  }

  for (final scope in AskEngineScope.values) {
    testWidgets('tuning saves only current scope ${scope.name}',
        (tester) async {
      final api = _Api();
      await open(tester, api, scope: scope);
      await tester.tap(find.byKey(const Key('agent-change-effort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('高').last);
      await tester.pumpAndSettle();
      expect(api.lastCodexEffort, 'high');
      await tester.ensureVisible(find.byKey(const Key('agent-change-fast')));
      await tester.tap(find.byKey(const Key('agent-change-fast')));
      await tester.pumpAndSettle();
      expect(api.lastCodexFast, true);
      expect(api.lastCodexScope, scope.name);
      expect(api.codexOptionsByScope[scope.name]?['codex-test-a'],
          {'effort': 'high', 'fast': true});
      final other = scope == AskEngineScope.book ? 'repo' : 'book';
      expect(api.codexOptionsByScope[other] ?? {}, isEmpty);
    });
  }

  testWidgets('failed tuning keeps old value and allows retry', (tester) async {
    final api = _Api()..failCodexSave = true;
    await open(tester, api);
    await tester.ensureVisible(find.byKey(const Key('agent-change-fast')));
    await tester.tap(find.byKey(const Key('agent-change-fast')));
    await tester.pumpAndSettle();
    expect(find.textContaining('参数保存失败'), findsOneWidget);
    expect(
        tester.widget<Switch>(find.byKey(const Key('agent-change-fast'))).value,
        false);
    api.failCodexSave = false;
    await tester.tap(find.byKey(const Key('agent-change-fast')));
    await tester.pumpAndSettle();
    expect(
        tester.widget<Switch>(find.byKey(const Key('agent-change-fast'))).value,
        true);
    await tester.ensureVisible(find.text('切换模型'));
    await choose(tester, 'codex-test-b');
    expect(find.byKey(const Key('agent-change-fast')), findsNothing);
    expect(find.byKey(const Key('agent-change-effort')), findsNothing);
  });

  testWidgets('failed switch preserves the current model and can retry',
      (tester) async {
    final api = _Api()..failCodexSave = true;
    await open(tester, api);
    await choose(tester, 'codex-test-b');
    expect(find.textContaining('切换失败'), findsOneWidget);
    expect(find.text('当前模型：codex-test-a'), findsOneWidget);
    api.failCodexSave = false;
    await choose(tester, 'codex-test-b');
    expect(find.text('当前模型：codex-test-b'), findsOneWidget);
    expect(find.textContaining('切换失败'), findsNothing);
  });

  testWidgets(
      'saving blocks overlapping operations and safely survives closing',
      (tester) async {
    final api = _Api()..savePending = Completer<void>();
    await open(tester, api);
    await choose(tester, 'codex-test-b');
    expect(api.saveCalls, 1);
    expect(
        tester
            .widget<TextButton>(find.byKey(const Key('agent-change-model')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<TextButton>(find.byKey(const Key('agent-model-speed')))
            .onPressed,
        isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    api.savePending!.complete();
    await tester.pumpAndSettle();
    expect(api.codexModelsByScope['repo'], 'codex-test-b');
    expect(tester.takeException(), isNull);
  });

  testWidgets('book panel long press opens book model settings on a phone',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _Api();
    final size = ValueNotifier<double>(0.6);
    final scroll = ScrollController();
    addTearDown(size.dispose);
    addTearDown(scroll.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: BookAskPanel(
      api: api,
      book: BookItem(
          id: 'demo',
          filename: 'demo.epub',
          title: '演示书',
          author: '',
          language: 'zh',
          size: 100,
          modifiedAt: '',
          hasCover: false),
      scrollController: scroll,
      sheetSize: size,
      expanded: true,
    ))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester
        .longPress(find.byKey(const ValueKey('agent-model-button-book')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('问书 · Agent 详情'), findsOneWidget);
    await tester.tap(find.text('切换模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('agent-model-codex-test-b')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.lastCodexScope, 'book');
    expect(api.codexModelsByScope['repo'], 'codex-test-a');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('prevents duplicate tests and safely closes while pending',
      (tester) async {
    final api = _Api()..pending = Completer<Map<String, dynamic>>();
    await open(tester, api);
    await tester.tap(find.text('模型测速'));
    await tester.pump();
    await tester.tap(find.text('正在测速…'));
    expect(api.speedCalls, 1);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    api.pending!.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh recovers model failure and missing tokens are explicit',
      (tester) async {
    final api = _Api()..fail = true;
    await open(tester, api);
    expect(find.text('模型信息获取失败，请刷新重试。'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('思考强度：低'), findsOneWidget);
    api.pending = Completer<Map<String, dynamic>>();
    await tester.tap(find.text('模型测速'));
    await tester.pump();
    api.pending!.completeError(Exception('offline'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测速失败'), findsOneWidget);
    api.pending = Completer<Map<String, dynamic>>();
    await tester.tap(find.text('模型测速'));
    api.pending!.complete({'firstTokenMs': 100, 'tokensPerSecond': null});
    await tester.pumpAndSettle();
    expect(find.textContaining('无法计算 token/秒'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
