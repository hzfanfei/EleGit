import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

void main() {
  test('splits fenced code from prose', () {
    const src = '说明如下：\n```\nvoid main() {}\n```\n结束';
    final parts = splitRichBlocks(src);
    expect(parts, hasLength(3));
    expect(parts[0].kind, RichKind.prose);
    expect(parts[1].kind, RichKind.code);
    expect(parts[1].text, contains('void main()'));
    expect(parts[1].language, '');
    expect(parts[2].kind, RichKind.prose);
  });

  test('keeps language on a closed fence', () {
    const src = '说明如下：\n```dart\nvoid main() {}\n```\n结束';
    final parts = splitRichBlocks(src);
    expect(parts[1].kind, RichKind.code);
    expect(parts[1].language, 'dart');
    expect(parts[1].text, 'void main() {}');
  });

  test('keeps an unclosed fence as a code block', () {
    const src = '说明：\n```\nvoid main() {';
    final parts = splitRichBlocks(src);
    expect(parts, hasLength(2));
    expect(parts[0].kind, RichKind.prose);
    expect(parts[1].kind, RichKind.code);
    expect(parts[1].text, contains('void main()'));
  });

  test('keeps an opening fence with no newline as a code block', () {
    const src = '说明：\n```dart';
    final parts = splitRichBlocks(src);
    expect(parts, hasLength(2));
    expect(parts[0].kind, RichKind.prose);
    expect(parts[1].kind, RichKind.code);
    expect(parts[1].language, 'dart');
  });

  test('parses a github-style markdown table', () {
    const src = '| 名称 | 状态 |\n| --- | --- |\n| 登录 | 已完成 |\n| 克隆 | 进行中 |';
    final table = parseMarkdownTable(src);
    expect(table, isNotNull);
    expect(table!.headers, ['名称', '状态']);
    expect(table.rows, [
      ['登录', '已完成'],
      ['克隆', '进行中'],
    ]);
  });

  test('keeps a header-only table while it is still streaming', () {
    const src = '| 名称 | 状态 |';
    final table = parseMarkdownTable(src);
    expect(table, isNotNull);
    expect(table!.headers, ['名称', '状态']);
    expect(table.rows, isEmpty);
  });

  testWidgets('renders headings and lists without raw markers', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: WxReadableText('## 最近\n- 修登录\n1. 打开仓库'),
        ),
      ),
    );
    expect(find.text('最近'), findsOneWidget);
    expect(find.textContaining('修登录'), findsOneWidget);
    expect(find.textContaining('打开仓库'), findsOneWidget);
    expect(find.textContaining('##'), findsNothing);
  });

  testWidgets('renders bold and inline code while a fence is still open', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: WxReadableText('先看 **README** 里的 `npm start`\n```\nvoid main() {'),
        ),
      ),
    );
    expect(find.textContaining('README'), findsOneWidget);
    expect(find.textContaining('npm start'), findsOneWidget);
    expect(find.textContaining('void main() {'), findsOneWidget);
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('shows a language label on fenced code and hides the fence', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: WxReadableText('```yaml\nname: 问象\n```'),
        ),
      ),
    );
    expect(find.text('yaml'), findsOneWidget);
    expect(find.textContaining('name: 问象'), findsOneWidget);
    expect(find.textContaining('```'), findsNothing);
    expect(find.byKey(const Key('wx-code-block')), findsOneWidget);
    expect(_horizontalScrolls, findsNothing);
    expect(find.byTooltip('复制'), findsOneWidget);
  });

  testWidgets('unclosed fence with a language still looks like a code block', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: WxReadableText('开始\n```dart'),
        ),
      ),
    );
    expect(find.text('dart'), findsOneWidget);
    expect(find.byKey(const Key('wx-code-block')), findsOneWidget);
    expect(_horizontalScrolls, findsNothing);
    expect(find.textContaining('```'), findsNothing);
  });

  testWidgets('copy button puts the code on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
        return;
      }
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: WxReadableText('```dart\nvoid main() {}\n```'),
        ),
      ),
    );
    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copied, 'void main() {}');
  });

  testWidgets('renders table columns without raw pipes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: WxReadableText(
            '## 进度\n\n| 名称 | 状态 |\n| --- | --- |\n| 登录 | 已完成 |\n| 克隆 | 进行中 |',
          ),
        ),
      ),
    );
    expect(find.text('进度'), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);
    expect(find.text('状态'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('克隆'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.textContaining('|'), findsNothing);
    expect(find.textContaining('---'), findsNothing);
    expect(find.byKey(const Key('wx-md-table')), findsOneWidget);
    expect(_horizontalScrolls, findsNothing);
  });

  testWidgets('wide table and long code fit the screen without sideways scrolling', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 160,
              child: WxReadableText(
                '| 很长的列名甲 | 很长的列名乙 | 很长的列名丙 |\n'
                '| --- | --- | --- |\n'
                '| 单元格内容甲 | 单元格内容乙 | 单元格内容丙 |\n\n'
                '```js\nconst token = "${'x' * 80}";\n```',
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(_horizontalScrolls, findsNothing);
    expect(find.textContaining('很长的列名甲'), findsOneWidget);
    expect(find.textContaining('const token'), findsOneWidget);

    expect(tester.getSize(find.byKey(const Key('wx-md-table'))).width, lessThanOrEqualTo(160));
    expect(tester.getSize(find.byKey(const Key('wx-code-block'))).width, lessThanOrEqualTo(160));
  });

  testWidgets('reply frame stays snug under the text', (tester) async {
    const sample = '最近在修登录，改完回调再看上下文。';
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: WxReplyFrame(
                label: '问象',
                child: Text(sample),
              ),
            ),
          ),
        ),
      ),
    );
    final frame = tester.getSize(find.byType(WxReplyFrame));
    final text = tester.getSize(find.text(sample));
    expect(frame.height, lessThan(text.height + 80));
  });
}

final _horizontalScrolls = find.byWidgetPredicate(
  (widget) => widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal,
);
