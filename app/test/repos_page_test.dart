import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/screens/repos_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('repos list shows owner, privacy and opens after checkout', (tester) async {
    final api = FakeWenxiangApi(checkoutDelay: const Duration(milliseconds: 40));
    RepoItem? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ReposPage(
          api: api,
          githubLogin: 'octo',
          onOpen: (repo) => opened = repo,
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('仓库'), findsOneWidget);
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
    expect(find.text('准备'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(api.checkoutCalls, 1);
    expect(opened?.fullName, 'octo/demo');
  });

  testWidgets('repos empty state is explicit', (tester) async {
    final emptyApi = FakeWenxiangApi(reposResult: []);
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ReposPage(api: emptyApi, onOpen: (_) {}, onBack: () {}),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('没有找到仓库'), findsOneWidget);
  });

  testWidgets('repos error state is readable Chinese', (tester) async {
    final errApi = FakeWenxiangApi(reposThrows: ApiException('HTTP 401 Unauthorized'));
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ReposPage(api: errApi, onOpen: (_) {}, onBack: () {}),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.textContaining('授权'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('clone failure stays on the overlay', (tester) async {
    final errApi = FakeWenxiangApi(
      checkoutDelay: const Duration(milliseconds: 20),
      checkoutThrows: ApiException('git clone failed: Authentication failed'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ReposPage(api: errApi, onOpen: (_) {}, onBack: () {}),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    await tester.tap(find.text('demo'));
    await tester.pump();
    expect(find.textContaining('~/问象/octo/demo'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();
    expect(find.text('没有落到本机'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.textContaining('克隆'), findsWidgets);
    expect(find.textContaining('检出'), findsNothing);
  });
}
