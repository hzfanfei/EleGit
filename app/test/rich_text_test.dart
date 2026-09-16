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
}
