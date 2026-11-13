import 'package:wenxiang/copy/ask_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/log_center_page.dart';
import 'package:wenxiang/screens/settings_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
  for (var i = 0; i < 30; i += 1) {
    if (finder.evaluate().isNotEmpty) {
      final rect = tester.getRect(finder.first);
      if (rect.top >= 64 && rect.bottom <= 560) return;
      scrollable.position.jumpTo((scrollable.position.pixels + rect.top - 120)
          .clamp(0.0, scrollable.position.maxScrollExtent));
      await tester.pump();
      continue;
    }
    final next = (scrollable.position.pixels + 280)
        .clamp(0.0, scrollable.position.maxScrollExtent);
    if (next == scrollable.position.pixels) return;
    scrollable.position.jumpTo(next);
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings page lists Volcengine voices and saves the pick',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('智能问答'), findsOneWidget);
    expect(find.text('Claude Code'), findsNothing);
    expect(find.text('Codex'), findsNWidgets(2));
    expect(find.text('问书'), findsOneWidget);
    expect(find.text('问象'), findsOneWidget);
    await _reveal(tester, find.text('语音'));
    expect(find.text('语音'), findsOneWidget);
    final yunzhou = find.textContaining('云舟');
    await _reveal(tester, yunzhou);
    await tester.tap(yunzhou.first);
    await tester.pumpAndSettle();
    expect(memory.ttsVoice(), 'zh_male_m191_uranus_bigtts');
    expect(api.lastSetTtsVoice, 'zh_male_m191_uranus_bigtts');
  });

  testWidgets('settings page lists CosyVoice when server uses local TTS',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api =
        FakeWenxiangApi(voiceReady: true, voiceTtsProvider: 'cosyvoice');
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    await _reveal(tester, find.textContaining('CosyVoice3'));
    expect(find.textContaining('CosyVoice3'), findsWidgets);
    final xiaohe = find.textContaining('小何');
    await _reveal(tester, xiaohe);
    expect(xiaohe, findsWidgets);
    await _reveal(tester, find.textContaining('云舟'));
    expect(find.textContaining('云舟'), findsOneWidget);
  });

  testWidgets('settings page switches local and volc voice together',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api =
        FakeWenxiangApi(voiceReady: true, voiceTtsProvider: 'cosyvoice');
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    await _reveal(tester, find.text('语音'));
    expect(find.text('语音'), findsOneWidget);
    await _reveal(tester, find.text('本地'));
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('火山'), findsOneWidget);
    expect(find.textContaining('FunASR'), findsWidgets);

    await _reveal(tester, find.text('火山'));
    await tester.tap(find.text('火山'));
    await tester.pumpAndSettle();

    expect(api.lastSetVoiceStack, 'volc');
    await _reveal(tester, find.textContaining('火山引擎音色'));
    expect(find.textContaining('火山引擎音色'), findsOneWidget);
    expect(find.textContaining('CosyVoice3'), findsNothing);
  });

  testWidgets('settings page switches to the MiniMax voice stack',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi(voiceReady: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    await _reveal(tester, find.text('MiniMax'));
    expect(find.text('MiniMax'), findsOneWidget);
    expect(find.text('小米'), findsNothing);
    expect(find.text('MiniMax 识别，MiniMax 合成。'), findsOneWidget);

    await tester.tap(find.text('MiniMax'));
    await tester.pumpAndSettle();

    expect(api.lastSetVoiceStack, 'minimax');
    await _reveal(tester, find.textContaining('MiniMax 语音'));
    expect(find.textContaining('MiniMax 语音'), findsOneWidget);
    await _reveal(tester, find.text('少女音色'));
    expect(find.text('少女音色'), findsWidgets);
  });

  testWidgets('settings page runs diagnostics probe', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi(voiceReady: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('运行检测'), 500);
    await tester.tap(find.text('运行检测'));
    await tester.pumpAndSettle();

    expect(find.text('全部通过'), findsOneWidget);
    expect(find.text('问书模型'), findsOneWidget);
    expect(find.text('问象模型'), findsOneWidget);
    expect(find.text('语音合成'), findsOneWidget);
  });

  testWidgets('settings header opens log center', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('wx-settings-log-center')));
    await tester.pumpAndSettle();
    expect(find.byType(LogCenterPage), findsOneWidget);
  });

  testWidgets('Codex models and tuning stay independent by scope',
      (tester) async {
    SharedPreferences.setMockInitialValues({'wx.askEngine': 'cursor'});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi();
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(), home: SettingsPage(api: api, memory: memory)));
    await tester.pumpAndSettle();
    expect(find.text('Cursor'), findsNothing);
    expect(find.text('Claude Code'), findsNothing);
    expect(find.text('Codex'), findsNWidgets(2));

    final book = find.byKey(const Key('codex-book'));
    final slider = find.descendant(of: book, matching: find.byType(Slider));
    tester.widget<Slider>(slider).onChanged!(1);
    await tester.pump();
    expect(api.lastCodexEffort, isNull);
    tester.widget<Slider>(slider).onChangeEnd!(1);
    await tester.pumpAndSettle();
    expect(api.lastCodexScope, 'book');
    expect(api.lastCodexEffort, 'high');
    expect(api.codexOptionsByScope['repo'], isNull);

    await tester.tap(find.descendant(of: book, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(api.lastCodexFast, true);
    expect(api.codexOptionsByScope['repo'], isNull);

    final repoModel = find.byKey(const Key('codex-repo-model'));
    await _reveal(tester, repoModel);
    await tester.tap(repoModel);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('codex-option-codex-test-b')));
    await tester.pumpAndSettle();
    expect(api.codexModelsByScope['repo'], 'codex-test-b');
    expect(api.codexModelsByScope['book'], 'codex-test-a');

    expect(find.text('刷新模型'), findsNothing);
    expect(api.codexRefreshes, 1);
    expect(find.text('Codex Test A'), findsOneWidget);
    expect(find.text('Codex Test B'), findsOneWidget);
  });

  for (final capability in [
    (efforts: <String>[], fast: false, slider: false),
    (efforts: ['high'], fast: false, slider: false),
    (efforts: ['high', 'high'], fast: false, slider: false),
    (efforts: ['none', 'high'], fast: false, slider: true),
    (efforts: <String>[], fast: true, slider: false),
    (efforts: ['low', 'high'], fast: true, slider: true),
  ]) {
    testWidgets(
        'model controls follow capabilities ${capability.efforts} fast=${capability.fast}',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = _CapabilityApi(capability.efforts, capability.fast);
      await tester.pumpWidget(
          MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('codex-book'));
      expect(find.descendant(of: card, matching: find.text('思考强度')),
          capability.slider ? findsOneWidget : findsNothing);
      expect(find.descendant(of: card, matching: find.byType(Slider)),
          capability.slider ? findsOneWidget : findsNothing);
      expect(find.descendant(of: card, matching: find.text('快速模式')),
          capability.fast ? findsOneWidget : findsNothing);
      expect(find.descendant(of: card, matching: find.byType(Switch)),
          capability.fast ? findsOneWidget : findsNothing);
    });
  }

  testWidgets(
      'model speed test uses the chosen scope and displays tokens per second',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeWenxiangApi();
    await tester.pumpWidget(
        MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
    await tester.pumpAndSettle();
    final button = find.descendant(
        of: find.byKey(const Key('codex-book')), matching: find.text('模型测速'));
    await _reveal(tester, button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(api.lastSpeedScope, AskEngineScope.book);
    expect(find.textContaining('42.5 token/秒'), findsOneWidget);
  });

  testWidgets('failed model save preserves the previous selection',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeWenxiangApi()..failCodexSave = true;
    await tester.pumpWidget(
        MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('codex-book-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('codex-option-codex-test-b')));
    await tester.pumpAndSettle();
    expect(api.codexModelsByScope['book'], 'codex-test-a');
    expect(find.text('Codex Test A'), findsNWidgets(2));
    expect(find.textContaining('保存失败，当前配置未更改'), findsOneWidget);
  });
}

class _CapabilityApi extends FakeWenxiangApi {
  _CapabilityApi(this.efforts, this.fast);
  final List<String> efforts;
  final bool fast;
  @override
  Future<Map<String, dynamic>> codexModels() async {
    final result = await super.codexModels();
    final model = (result['models'] as List).first as Map;
    model['reasoningEfforts'] = efforts;
    if (efforts.isEmpty) {
      model.remove('defaultReasoningEffort');
    } else {
      model['defaultReasoningEffort'] = efforts.first;
    }
    model['supportsFast'] = fast;
    return result;
  }
}
