import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/settings_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

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
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('语音音色'), findsOneWidget);
    expect(find.textContaining('小何'), findsWidgets);

    await tester.scrollUntilVisible(find.textContaining('云舟'), 400);
    await tester.tap(find.textContaining('云舟').first);
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
    expect(find.textContaining('小何'), findsOneWidget);
    expect(find.textContaining('云舟'), findsOneWidget);
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

    await tester.tap(find.text('Cursor'));
    await tester.pumpAndSettle();
    expect(memory.askEngine(), AskEngineChoice.cursor);
    expect(api.lastSetAskEngine, 'cursor');
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
    expect(find.text('模型回复'), findsOneWidget);
    expect(find.text('语音合成'), findsOneWidget);
  });
}
