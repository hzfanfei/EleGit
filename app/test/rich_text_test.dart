import 'package:flutter/material.dart';
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
    expect(parts[2].kind, RichKind.prose);
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
}
