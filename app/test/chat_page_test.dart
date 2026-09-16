import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/screens/chat_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('empty chat is a short prompt, not a chip wall', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('octo/demo'), findsWidgets);
    expect(find.textContaining('对着这份检出提问'), findsOneWidget);
    expect(find.text('这个仓库最近在做什么？'), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text('▍'), findsNothing);
    expect(find.text('API Key'), findsNothing);
  });

  testWidgets('streaming reply appears without a block caret placeholder', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('这个仓库最近在做什么？'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('最近在修登录'), findsOneWidget);
    expect(find.text('▍'), findsNothing);
    expect(find.textContaining('本地进度'), findsWidgets);
  });

  testWidgets('session start and history stay on the quiet chrome, not an AppBar', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ChatPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AppBar), findsNothing);
    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(find.byTooltip('历史会话'), findsOneWidget);

    await tester.tap(find.byTooltip('新建会话'));
    await tester.pump();
    expect(find.textContaining('对着这份检出提问'), findsOneWidget);

    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    expect(find.text('历史会话'), findsOneWidget);
    expect(find.text('新会话'), findsWidgets);
  });
}
