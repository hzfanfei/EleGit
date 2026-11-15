import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_chat_markdown_stream.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

void main() {
  Future<void> show(WidgetTester tester, ValueNotifier<String> source,
      {void Function(String, String)? onLink}) async {
    await tester.pumpWidget(MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
            body: SingleChildScrollView(
                child: SizedBox(
                    width: 360,
                    child: WxChatMarkdownStream(
                        source: source,
                        mdStyle: chatMarkdownStyle(wenxiangTheme()),
                        onTapLink: onLink))))));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'duplicate paragraphs have unique stable elements and visible gaps',
      (tester) async {
    final source = ValueNotifier('重复段落。\n\n重复段落。\n\n尾段');
    await show(tester, source);
    expect(tester.takeException(), isNull);
    final first = find.byKey(const ValueKey('answer-block-0'));
    final second = find.byKey(const ValueKey('answer-block-1'));
    final tail = find.byKey(const ValueKey('answer-block-2'));
    final firstElement = tester.element(first);
    final tailElement = tester.element(tail);
    expect((tester.widget<Padding>(second)).padding,
        const EdgeInsets.only(top: 10));
    source.value += '继续\n\n下一段';
    await tester.pumpAndSettle();
    expect(identical(tester.element(first), firstElement), isTrue);
    expect(identical(tester.element(tail), tailElement), isTrue);
    expect(find.byType(AnimatedSize), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('callout markers become labelled cards', (tester) async {
    await show(
        tester, ValueNotifier('> [!WARNING]\n> 请先保存。\n\n> [!TIP]\n> 可以重试。'));
    expect(find.text('注意'), findsOneWidget);
    expect(find.text('提示'), findsOneWidget);
    expect(find.textContaining('[!WARNING]'), findsNothing);
    expect(find.textContaining('请先保存', findRichText: true), findsOneWidget);
  });

  testWidgets('details remain expanded while streaming and when completed',
      (tester) async {
    final source = ValueNotifier('<details>\n<summary>验证详情</summary>\n\n第一项');
    await show(tester, source);
    await tester.tap(find.text('验证详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第一项', findRichText: true), findsOneWidget);
    source.value += '\n\n第二项\n</details>\n\n继续';
    await tester.pumpAndSettle();
    expect(find.textContaining('第二项', findRichText: true), findsOneWidget);
    expect(find.text('内容接收中…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'standalone downloads preserve exact URL and inline links stay inline',
      (tester) async {
    const url = 'https://example.com/files/app.apk?token=a%2Bb';
    String? opened;
    await show(tester, ValueNotifier('[下载安装包]($url)'),
        onLink: (href, _) => opened = href);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    await tester.tap(find.text('下载安装包'));
    expect(opened, url);
    await show(tester, ValueNotifier('请看 [安装包]($url)，然后继续。'));
    expect(find.byIcon(Icons.download_outlined), findsNothing);
  });

  testWidgets('task marker becomes a status label and preserves code examples',
      (tester) async {
    await show(tester, ValueNotifier('===TASK_COMPLETED===\n已处理。'));
    expect(find.text('✓ 任务已完成'), findsOneWidget);
    expect(find.textContaining('===TASK_COMPLETED==='), findsNothing);
    await show(
        tester,
        ValueNotifier(
            '```text\n===TASK_COMPLETED===\n> [!NOTE]\n<details>\n<summary>示例</summary>\n</details>\n```'));
    expect(find.text('✓ 任务已完成'), findsNothing);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.widget<WxFencedCode>(find.byType(WxFencedCode)).code,
        contains('===TASK_COMPLETED==='));
  });

  testWidgets('completion after streamed progress never leaks into the answer',
      (tester) async {
    final source = ValueNotifier('片尾音乐已修正，正在复检最终文件。\n\n');
    await show(tester, source);
    expect(find.text('✓ 任务已完成'), findsNothing);
    source.value += '===TASK_COMPLETED===做好了：视频已通过检查。';
    await tester.pumpAndSettle();
    expect(find.text('✓ 任务已完成'), findsOneWidget);
    expect(find.textContaining('===TASK_COMPLETED==='), findsNothing);
    expect(find.textContaining('片尾音乐已修正', findRichText: true), findsOneWidget);
    expect(find.textContaining('做好了：视频已通过检查。', findRichText: true),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code containing download links stays code', (tester) async {
    await show(
        tester, ValueNotifier('```md\n[安装](https://example.com/a.apk)\n```'));
    expect(find.byIcon(Icons.download_outlined), findsNothing);
    expect(find.byKey(const Key('wx-md-code')), findsOneWidget);
  });
}
