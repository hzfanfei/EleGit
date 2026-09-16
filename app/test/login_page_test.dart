import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/screens/login_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('login explains browser authorization and can retry', (tester) async {
    final api = FakeWenxiangApi();
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: LoginPage(
          api: api,
          onReady: () async {},
          openUrl: (uri) async {
            opened = uri;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('问象'), findsWidgets);
    expect(find.textContaining('浏览器'), findsWidgets);
    expect(find.text('重新打开 GitHub'), findsOneWidget);
    expect(opened?.host, 'github.com');
    expect(api.startOAuthCalls, 1);

    await tester.tap(find.text('重新打开 GitHub'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.startOAuthCalls, 2);
  });

  testWidgets('login shows a readable error instead of a stack', (tester) async {
    final api = FakeWenxiangApi(
      oauthThrows: ApiException('SocketException: Connection refused'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: LoginPage(
          api: api,
          onReady: () async {},
          openUrl: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('连不上本机问象服务'), findsWidgets);
    expect(find.textContaining('SocketException'), findsNothing);
    expect(find.text('API Key'), findsNothing);
  });

  testWidgets('returning from repos does not auto-open GitHub', (tester) async {
    final api = FakeWenxiangApi();
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: LoginPage(
          api: api,
          autoStart: false,
          onReady: () async {},
          openUrl: (_) async {
            opened += 1;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(api.startOAuthCalls, 0);
    expect(opened, 0);
    expect(find.textContaining('已从仓库返回'), findsOneWidget);

    await tester.tap(find.text('重新打开 GitHub'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.startOAuthCalls, 1);
    expect(opened, 1);
  });

  testWidgets('authorized beat appears before leaving login', (tester) async {
    final api = FakeWenxiangApi(oauthCompletes: true);
    var ready = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: LoginPage(
          api: api,
          onReady: () async {
            ready += 1;
          },
          openUrl: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(ready, 0);

    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('已授权'), findsWidgets);
    expect(ready, 0);

    await tester.pump(const Duration(milliseconds: 560));
    expect(ready, 1);
  });
}
