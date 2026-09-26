import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/settings_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
  for (var i = 0; i < 30; i += 1) {
    if (finder.evaluate().isNotEmpty) {
      final rect = tester.getRect(finder.first);
      if (rect.top >= 64 && rect.bottom <= 560) return;
    }
    final next = (scrollable.position.pixels + 280).clamp(0.0, scrollable.position.maxScrollExtent);
    if (next == scrollable.position.pixels) return;
    scrollable.position.jumpTo(next);
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('settings page lists Volcengine voices and saves the pick', (tester) async {
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
    expect(find.text('Claude Code'), findsWidgets);
    expect(find.text('问书'), findsOneWidget);
    expect(find.text('问象（仓库进度）'), findsOneWidget);
    expect(find.text('语音'), findsOneWidget);
    final yunzhou = find.textContaining('云舟');
    await _reveal(tester, yunzhou);
    await tester.tap(yunzhou.first);
    await tester.pumpAndSettle();
    expect(memory.ttsVoice(), 'zh_male_m191_uranus_bigtts');
    expect(api.lastSetTtsVoice, 'zh_male_m191_uranus_bigtts');
  });

  testWidgets('settings page lists CosyVoice when server uses local TTS', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi(voiceReady: true, voiceTtsProvider: 'cosyvoice');
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('CosyVoice3'), findsWidgets);
    final xiaohe = find.textContaining('小何');
    await _reveal(tester, xiaohe);
    expect(xiaohe, findsWidgets);
    await _reveal(tester, find.textContaining('云舟'));
    expect(find.textContaining('云舟'), findsOneWidget);
  });

  testWidgets('settings page switches local and volc voice together', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final api = FakeWenxiangApi(voiceReady: true, voiceTtsProvider: 'cosyvoice');
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
        home: SettingsPage(api: api, memory: memory),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('语音'), findsOneWidget);
    expect(find.text('本地'), findsOneWidget);
    expect(find.text('火山'), findsOneWidget);
    expect(find.textContaining('FunASR'), findsWidgets);

    await _reveal(tester, find.text('火山'));
    await tester.tap(find.text('火山'));
    await tester.pumpAndSettle();

    expect(api.lastSetVoiceStack, 'volc');
    expect(find.textContaining('火山引擎音色'), findsOneWidget);
    expect(find.textContaining('CosyVoice3'), findsNothing);
  });

  testWidgets('settings page switches to the Xiaomi voice stack', (tester) async {
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

    expect(find.text('小米'), findsOneWidget);
    expect(find.text('小米识别，小米合成。'), findsOneWidget);

    await _reveal(tester, find.text('小米'));
    await tester.tap(find.text('小米'));
    await tester.pumpAndSettle();

    expect(api.lastSetVoiceStack, 'xiaomi');
    expect(find.textContaining('小米 MiMo 语音'), findsOneWidget);
    await _reveal(tester, find.text('冰糖'));
    expect(find.text('冰糖'), findsOneWidget);
  });

  testWidgets('settings page saves ask engine choice', (tester) async {
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

    await tester.tap(find.text('Cursor').last);
    await tester.pumpAndSettle();
    expect(memory.askEngineRepo(), AskEngineChoice.cursor);
    expect(api.lastSetAskEngine, 'cursor');
    expect(api.lastSetAskEngineScope, 'repo');
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

  testWidgets('settings page saves ask engine for 问书', (tester) async {
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

    await tester.tap(find.text('Cursor').first);
    await tester.pumpAndSettle();
    expect(memory.askEngineBook(), AskEngineChoice.cursor);
    expect(api.lastSetAskEngine, 'cursor');
    expect(api.lastSetAskEngineScope, 'book');
  });
}
