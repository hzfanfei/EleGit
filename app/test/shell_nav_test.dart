import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/shell_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

ThemeData _theme() => wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppMemory> memory() async {
    SharedPreferences.setMockInitialValues({});
    return AppMemory(await SharedPreferences.getInstance());
  }

  testWidgets('authorized shell opens repo list as home', (tester) async {
    final store = await memory();
    await store.saveGithubLogin('octo');

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(api: FakeWenxiangApi(), memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('搜索仓库名'), findsOneWidget);
    expect(find.text('问象'), findsWidgets);
    expect(find.text('重新打开 GitHub'), findsNothing);
    expect(find.text('继续上次'), findsNothing);
  });

  testWidgets('last repo shortcut opens chat when present', (tester) async {
    final store = await memory();
    await store.saveLastRepo(sampleRepo());
    final api = FakeWenxiangApi();

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(api: api, memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('继续上次'), findsOneWidget);
    expect(find.text('打开对话'), findsOneWidget);
    await tester.tap(find.byKey(const Key('wx-home-last')));
    await tester.pumpAndSettle();
    expect(find.textContaining('从进度问起'), findsOneWidget);
  });

  testWidgets('repo tile opens chat with restored history', (tester) async {
    final store = await memory();
    await store.saveChats(
      'octo/demo',
      RepoChatStore(
        activeId: 's1',
        sessions: [
          ChatSession(
            id: 's1',
            title: '这个仓库最近在做什么？',
            createdAt: '2026-09-16T00:00:00Z',
            updatedAt: '2026-09-16T00:00:00Z',
            active: true,
          ),
        ],
        transcripts: {
          's1': [
            ChatMessage(role: 'user', content: '这个仓库最近在做什么？'),
            ChatMessage(role: 'assistant', content: '最近在修登录。', engine: 'local-progress'),
          ],
        },
      ),
    );
    final api = FakeWenxiangApi();

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(api: api, memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('demo').first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(api.checkoutCalls, 0);
    expect(find.textContaining('最近在修登录'), findsOneWidget);
    expect(find.text('你问'), findsOneWidget);
  });

  testWidgets('not logged in shows local repos on repo home', (tester) async {
    final store = await memory();
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(
          api: FakeWenxiangApi(githubConnected: false),
          memory: store,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('demo'), findsOneWidget);
    expect(find.text('连接 GitHub'), findsOneWidget);
    expect(find.text('重新打开 GitHub'), findsNothing);
  });

  testWidgets('back from chat returns to repo list without OAuth', (tester) async {
    final store = await memory();
    final api = FakeWenxiangApi();

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(api: api, memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('demo').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('从进度问起'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('搜索仓库名'), findsOneWidget);
    expect(api.startOAuthCalls, 0);
  });

  testWidgets('back on home does not leave the app', (tester) async {
    final store = await memory();
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(api: FakeWenxiangApi(), memory: store),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('搜索仓库名'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('搜索仓库名'), findsOneWidget);
    expect(find.byType(ShellPage), findsOneWidget);
  });

  testWidgets('edge swipes go back and never exit from home', (tester) async {
    final store = await memory();
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ShellPage(api: FakeWenxiangApi(), memory: store),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('demo').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.textContaining('从进度问起'), findsOneWidget);

    final left = await tester.startGesture(const Offset(8, 360));
    await left.moveBy(const Offset(90, 0));
    await left.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('搜索仓库名'), findsOneWidget);

    await tester.tap(find.text('demo').first, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final size = tester.getSize(find.byType(ShellPage));
    final right = await tester.startGesture(Offset(size.width - 8, 360));
    await right.moveBy(const Offset(-90, 0));
    await right.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('搜索仓库名'), findsOneWidget);

    final stay = await tester.startGesture(const Offset(8, 360));
    await stay.moveBy(const Offset(90, 0));
    await stay.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(ShellPage), findsOneWidget);
    expect(find.text('搜索仓库名'), findsOneWidget);
  });
}
