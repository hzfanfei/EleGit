import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_chat_markdown_stream.dart';

Future<void> _pumpWithSource(
  WidgetTester tester,
  String markdown, {
  bool showCaret = false,
}) async {
  final source = ValueNotifier<String>(markdown);
  await tester.pumpWidget(
    MaterialApp(
      theme: wenxiangTheme(),
      home: Scaffold(
        backgroundColor: Wx.bg,
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: WxChatMarkdownStream(
            source: source,
            styleSheet: chatMarkdownStyle(wenxiangTheme()),
            showCaret: showCaret,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  group('WxChatMarkdownStream — 之前聊天里常见的样例', () {
    testWidgets('标题与列表不出现 ## 和 - 原文', (tester) async {
      await _pumpWithSource(tester, '## 最近\n\n- 修登录\n\n1. 打开仓库\n');
      expect(tester.takeException(), isNull);
      expect(find.text('最近'), findsOneWidget);
      expect(find.textContaining('修登录'), findsOneWidget);
      expect(find.textContaining('打开仓库'), findsOneWidget);
      expect(find.textContaining('##'), findsNothing);
      expect(find.byType(MarkdownBody), findsWidgets);
    });

    testWidgets('表格列名与单元格，不出现裸 |', (tester) async {
      await _pumpWithSource(
        tester,
        '## 进度\n\n| 名称 | 状态 |\n| --- | --- |\n| 登录 | 已完成 |\n| 克隆 | 进行中 |\n',
      );
      expect(tester.takeException(), isNull);
      expect(find.text('进度'), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      expect(find.textContaining('名称'), findsWidgets);
      expect(find.textContaining('登录'), findsWidgets);
      expect(find.textContaining('进行中'), findsWidgets);
      expect(find.textContaining('| ---'), findsNothing);
    });

    testWidgets('链接可渲染为文字而非 [text](url) 原文', (tester) async {
      await _pumpWithSource(
        tester,
        '说明见 [官网](https://example.com) 与下文。\n',
        showCaret: false,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('官网'), findsWidgets);
      expect(find.textContaining('[官网](https://'), findsNothing);
    });

    testWidgets('围栏代码块带语言标签、无 ``` 泄漏', (tester) async {
      await _pumpWithSource(
        tester,
        '先看 **README** 里的 `npm start`\n\n```yaml\nname: 问象\n```\n',
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('README'), findsOneWidget);
      expect(find.textContaining('npm start'), findsOneWidget);
      expect(find.textContaining('name: 问象'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
      expect(find.textContaining('```'), findsNothing);
    });

    testWidgets('引用与分割线', (tester) async {
      await _pumpWithSource(
        tester,
        '> 引用一句。\n\n---\n\n正文继续。\n',
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('引用一句'), findsOneWidget);
      expect(find.textContaining('正文继续'), findsOneWidget);
      expect(find.textContaining('> 引用'), findsNothing);
    });

    testWidgets('流式：已完成块 Markdown，尾部纯文本', (tester) async {
      await _pumpWithSource(tester, '第一段已写完。\n\n第二段还在写', showCaret: true);
      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.textContaining('第二段还在写'), findsOneWidget);
    });
  });
}
