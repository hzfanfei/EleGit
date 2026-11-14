import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/widgets/agent_details_dialog.dart';
import 'support/fake_api.dart';

class _Api extends FakeWenxiangApi {
  Completer<Map<String, dynamic>>? pending;
  bool fail = false;
  int speedCalls = 0;
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
  Future<void> open(WidgetTester tester, _Api api) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            AgentDetailsDialog(api: api, agentMode: true)),
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
