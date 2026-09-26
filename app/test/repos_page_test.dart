import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/screens/repos_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

ThemeData _theme() => wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory);

void main() {
  testWidgets('repos list shows owner, privacy and opens after checkout', (tester) async {
    final api = FakeWenxiangApi(
      checkoutDelay: const Duration(milliseconds: 40),
      checkoutStatusResult: CheckoutSyncStatus(
        present: true,
        upToDate: false,
        syncState: 'behind',
        behind: 2,
        path: '/home/fei/问象/octo/demo',
      ),
    );
    RepoItem? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(
          api: api,
          githubLogin: 'octo',
          onOpen: (repo) => opened = repo,
          onAuthorized: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('问象'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('demo'), findsOneWidget);
    expect(find.textContaining('octo'), findsWidgets);
    expect(find.text('已登录'), findsNothing);
    expect(find.text('私有'), findsOneWidget);
    expect(find.text('测试连接'), findsNothing);
    expect(find.textContaining('检出'), findsNothing);

    await tester.tap(find.text('demo'));
    await tester.pump();
    expect(find.textContaining('~/问象/octo/demo'), findsWidgets);
    expect(
      tester.any(find.textContaining('正在')) || tester.any(find.textContaining('准备')),
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(api.checkoutCalls, 1);
    expect(opened?.fullName, 'octo/demo');
  });

  testWidgets('repos empty state is explicit', (tester) async {
    final emptyApi = FakeWenxiangApi(reposResult: []);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(api: emptyApi, onOpen: (_) {}, onAuthorized: () async {}),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('本机还没有仓库'), findsOneWidget);
  });

  testWidgets('github failure falls back to local repos without error panel', (tester) async {
    final errApi = FakeWenxiangApi(reposThrows: ApiException('HTTP 401 Unauthorized'));
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(
          api: errApi,
          githubConnected: true,
          onOpen: (_) {},
          onAuthorized: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('demo'), findsOneWidget);
    expect(find.textContaining('出了点问题'), findsNothing);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('offline home shows local repos list', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(
          api: FakeWenxiangApi(),
          githubConnected: false,
          onOpen: (_) {},
          onAuthorized: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('问象'), findsOneWidget);
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('连接 GitHub'), findsNothing);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('连接 GitHub'), findsOneWidget);
    expect(find.textContaining('出了点问题'), findsNothing);
  });

  testWidgets('home brand opens settings and has no extra settings button', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(
          api: FakeWenxiangApi(),
          githubConnected: false,
          onOpen: (_) {},
          onAuthorized: () async {},
          onOpenSettings: () => opened += 1,
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    expect(opened, 1);
  });

  testWidgets('clone failure stays on the overlay', (tester) async {
    final errApi = FakeWenxiangApi(
      checkoutDelay: const Duration(milliseconds: 20),
      checkoutThrows: ApiException('git clone failed: Authentication failed'),
      checkoutStatusResult: CheckoutSyncStatus(
        present: false,
        upToDate: false,
        syncState: 'missing',
        behind: 0,
        path: '/home/fei/问象/octo/demo',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(api: errApi, onOpen: (_) {}, onAuthorized: () async {}),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('demo'));
    await tester.pump();
    expect(find.textContaining('~/问象/octo/demo'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();
    expect(find.text('没有落到本机'), findsNothing);
    expect(find.textContaining('还没有写到本机'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.textContaining('克隆'), findsWidgets);
    expect(find.textContaining('检出'), findsNothing);
  });

  testWidgets('clone can be cancelled without leaving the list', (tester) async {
    final api = FakeWenxiangApi(
      checkoutDelay: const Duration(milliseconds: 80),
      checkoutStatusResult: CheckoutSyncStatus(
        present: false,
        upToDate: false,
        syncState: 'missing',
        behind: 0,
        path: '/home/fei/问象/octo/demo',
      ),
    );
    RepoItem? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: ReposPage(api: api, onOpen: (repo) => opened = repo, onAuthorized: () async {}),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('demo'));
    await tester.pump();
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(api.cancelCheckoutCalls, 1);
    expect(opened, isNull);
    expect(find.text('demo'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(opened, isNull);
  });
}
