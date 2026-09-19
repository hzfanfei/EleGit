import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    expect(find.text('语音音色'), findsOneWidget);
    expect(find.textContaining('小何'), findsWidgets);

    await tester.scrollUntilVisible(find.textContaining('云舟'), 400);
    await tester.tap(find.textContaining('云舟').first);
    await tester.pumpAndSettle();
    expect(memory.ttsVoice(), 'zh_male_m191_uranus_bigtts');
    expect(api.lastSetTtsVoice, 'zh_male_m191_uranus_bigtts');
  });
}
