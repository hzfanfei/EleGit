import 'dart:async';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/log_center_page.dart';
import 'package:wenxiang/screens/settings_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/codex_scope_settings.dart';
import 'package:wenxiang/widgets/wx_chrome.dart';

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

  testWidgets('shows Codex remaining usage', (tester) async {
    final api = FakeWenxiangApi();
    api.usage = {
      'primary': {'usedPercent': 25, 'windowDurationMins': 10080},
      'secondary': null,
    };
    await tester.pumpWidget(MaterialApp(
      theme: wenxiangTheme(),
      home: Scaffold(
          body: SingleChildScrollView(child: CodexScopeSettings(api: api))),
    ));
    await tester.pumpAndSettle();
    expect(find.text('7天额度剩余 75%'), findsOneWidget);
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('model cards fit a narrow phone at text scale $scale',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: CodexScopeSettings(api: _LongLabelApi()),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final scope in ['book', 'repo']) {
        final card = find.byKey(Key('codex-$scope'));
        final rect = tester.getRect(card);
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(304));
        final toggle = find.descendant(of: card, matching: find.byType(Switch));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.widget<Switch>(toggle).value, isTrue);
        expect(tester.takeException(), isNull);
      }
    });
  }

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

  testWidgets('model speed test animates the chosen scope until results arrive',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _PendingSpeedApi();
    await tester.pumpWidget(
        MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
    await tester.pumpAndSettle();
    final button = find.descendant(
        of: find.byKey(const Key('codex-book')), matching: find.text('模型测速'));
    await _reveal(tester, button);
    await tester.tap(button);
    await tester.pump();
    expect(find.text('正在测速…'), findsOneWidget);
    final progress = find.byType(WxLoading);
    expect(
        find.descendant(
            of: find.byKey(const Key('codex-book')), matching: progress),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const Key('codex-repo')), matching: progress),
        findsNothing);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isTrue);
    api.measured.complete();
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(find.text('正在测速…'), findsNothing);
    expect(api.lastSpeedScope, AskEngineScope.book);
    expect(find.textContaining('42.5 token/秒'), findsOneWidget);
  });

  testWidgets(
      'dragging and saving one scope leaves the other slider unchanged and enabled',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _PendingSaveApi();
    await tester.pumpWidget(
        MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
    await tester.pumpAndSettle();
    Finder slider(String scope) => find.descendant(
        of: find.byKey(Key('codex-$scope')), matching: find.byType(Slider));
    final repoValue = tester.widget<Slider>(slider('repo')).value;
    tester.widget<Slider>(slider('book')).onChanged!(1);
    await tester.pump();
    expect(tester.widget<Slider>(slider('book')).value, 1);
    expect(tester.widget<Slider>(slider('repo')).value, repoValue);
    tester.widget<Slider>(slider('book')).onChangeEnd!(1);
    await tester.pump();
    expect(tester.widget<Slider>(slider('book')).onChanged, isNotNull);
    expect(tester.widget<Slider>(slider('book')).value, 1);
    expect(tester.widget<Slider>(slider('repo')).onChanged, isNotNull);
    expect(tester.widget<Slider>(slider('repo')).value, repoValue);
    api.saved.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider('book')).value, 1);
    expect(tester.widget<Slider>(slider('repo')).value, repoValue);
  });

  testWidgets('tapping a slider keeps the card stable throughout saving',
      (tester) async {
    final api = _PendingSaveApi();
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
            body: SingleChildScrollView(child: CodexScopeSettings(api: api)))));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('codex-book'));
    final slider = find.descendant(of: card, matching: find.byType(Slider));
    final bounds = tester.getRect(card);
    final element = tester.element(slider);
    await tester.tapAt(tester.getCenter(slider) + const Offset(100, 0));
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, 1);
    expect(tester.widget<Slider>(slider).onChanged, isNotNull);
    expect(tester.getRect(card), bounds);
    expect(tester.element(slider), same(element));
    expect(
        tester
            .widget<ListTile>(find.byKey(const Key('codex-book-model')))
            .enabled,
        isTrue);
    expect(
        tester
            .widget<Switch>(
                find.descendant(of: card, matching: find.byType(Switch)))
            .onChanged,
        isNotNull);
    api.saved.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 1);
    expect(tester.getRect(card), bounds);
    expect(api.lastCodexEffort, 'high');
  });

  testWidgets('rapid tuning edits are queued and preserve the latest values',
      (tester) async {
    final api = _PendingSaveApi();
    await tester.pumpWidget(
        MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('codex-book'));
    final slider = find.descendant(of: card, matching: find.byType(Slider));
    final toggle = find.descendant(of: card, matching: find.byType(Switch));
    tester.widget<Slider>(slider).onChangeEnd!(1);
    await tester.pump();
    tester.widget<Slider>(slider).onChangeEnd!(0);
    tester.widget<Switch>(toggle).onChanged!(true);
    await tester.pump();
    expect(tester.widget<Slider>(slider).value, 0);
    expect(tester.widget<Switch>(toggle).value, isTrue);
    expect(api.calls, hasLength(1));
    api.saved.complete();
    await tester.pumpAndSettle();
    expect(api.calls, hasLength(2));
    expect(api.lastCodexEffort, 'low');
    expect(api.lastCodexFast, isTrue);
    expect(tester.widget<Slider>(slider).value, 0);
    expect(tester.widget<Switch>(toggle).value, isTrue);
  });

  testWidgets('failed tuning save rolls back and allows retry', (tester) async {
    final api = _PendingSaveApi()..failCodexSave = true;
    await tester.pumpWidget(
        MaterialApp(theme: wenxiangTheme(), home: SettingsPage(api: api)));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('codex-book'));
    final slider = find.descendant(of: card, matching: find.byType(Slider));
    final toggle = find.descendant(of: card, matching: find.byType(Switch));
    tester.widget<Slider>(slider).onChangeEnd!(1);
    tester.widget<Switch>(toggle).onChanged!(true);
    await tester.pump();
    api.saved.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 0);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    expect(find.textContaining('保存失败，当前配置未更改'), findsOneWidget);
    api.failCodexSave = false;
    tester.widget<Slider>(slider).onChangeEnd!(1);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 1);
    expect(api.lastCodexEffort, 'high');
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

class _PendingSpeedApi extends FakeWenxiangApi {
  final measured = Completer<void>();
  @override
  Future<Map<String, dynamic>> measureModelSpeed(AskEngineScope scope) async {
    await measured.future;
    return super.measureModelSpeed(scope);
  }
}

class _LongLabelApi extends FakeWenxiangApi {
  @override
  Future<Map<String, dynamic>> codexModels() async {
    final result = await super.codexModels();
    ((result['models'] as List).first as Map)['label'] =
        'Codex Long Model Name · Extended Reasoning';
    return result;
  }
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

class _PendingSaveApi extends FakeWenxiangApi {
  final saved = Completer<void>();
  final calls = <({String? effort, bool? fast})>[];
  @override
  Future<void> setCodexModel(String model,
      {required AskEngineScope scope,
      String? effort,
      bool? fast,
      bool select = true}) async {
    calls.add((effort: effort, fast: fast));
    await saved.future;
    await super.setCodexModel(model,
        scope: scope, effort: effort, fast: fast, select: select);
  }
}
