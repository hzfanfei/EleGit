import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/shell_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppMemory> memory() async {
    SharedPreferences.setMockInitialValues({});
    return AppMemory(await SharedPreferences.getInstance());
  }

  testWidgets('authorized home shows last repo instead of login or search', (tester) async {
    final store = await memory();
    await store.saveLastRepo(sampleRepo());
    await store.saveGithubLogin('octo');

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ShellPage(api: FakeWenxiangApi(), memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('继续上次'), findsOneWidget);
    expect(find.text('octo/demo'), findsWidgets);
    expect(find.text('打开对话'), findsOneWidget);
    expect(find.text('全部仓库'), findsOneWidget);
    expect(find.text('搜索仓库名'), findsNothing);
    expect(find.text('重新打开 GitHub'), findsNothing);
    expect(find.textContaining('最近在修登录'), findsNothing);
  });

  testWidgets('one tap on last repo clones if needed and opens chat history', (tester) async {
    final store = await memory();
    await store.saveLastRepo(sampleRepo());
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
        theme: wenxiangTheme(),
        home: ShellPage(api: api, memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('wx-home-last')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(api.checkoutCalls, 1);
    expect(find.textContaining('最近在修登录'), findsOneWidget);
    expect(find.text('你问'), findsOneWidget);
    expect(find.text('问象'), findsWidgets);
  });

  testWidgets('authorized with repos but no last-used still offers a shortcut', (tester) async {
    final store = await memory();
    final api = FakeWenxiangApi(
      reposResult: [
        sampleRepo(),
        RepoItem(
          owner: 'octo',
          name: 'widget',
          fullName: 'octo/widget',
          description: '',
          privateRepo: false,
          language: 'Go',
          pushedAt: '2026-09-16T00:00:00Z',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ShellPage(api: api, memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('全部仓库'), findsOneWidget);
    expect(find.text('octo/demo'), findsWidgets);
    expect(find.text('重新打开 GitHub'), findsNothing);
    expect(find.text('搜索仓库名'), findsNothing);
  });

  testWidgets('not logged in keeps the OAuth path', (tester) async {
    final store = await memory();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ShellPage(
          api: FakeWenxiangApi(githubConnected: false),
          memory: store,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('重新打开 GitHub'), findsOneWidget);
    expect(find.text('继续上次'), findsNothing);
  });

  testWidgets('back walks chat to home to login without reopening GitHub', (tester) async {
    final store = await memory();
    await store.saveLastRepo(sampleRepo());
    final api = FakeWenxiangApi();

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ShellPage(api: api, memory: store),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('wx-home-last')));
    await tester.pumpAndSettle();
    expect(find.textContaining('从进度问起'), findsOneWidget);
    expect(find.text('octo/demo'), findsWidgets);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('继续上次'), findsOneWidget);
    expect(find.text('全部仓库'), findsOneWidget);
    expect(api.startOAuthCalls, 0);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.textContaining('已从仓库返回'), findsOneWidget);
    expect(api.startOAuthCalls, 0);
    expect(find.text('重新打开 GitHub'), findsOneWidget);
  });
}
