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
          onOpen: (repo) => opened = repo,
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('选择仓库'), findsOneWidget);
    expect(find.text('octo/demo'), findsOneWidget);
    expect(find.text('私有'), findsOneWidget);
    expect(find.text('测试连接'), findsNothing);

    await tester.tap(find.text('octo/demo'));
    await tester.pump();
    expect(find.textContaining('正在把 octo/demo'), findsWidgets);
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
}
