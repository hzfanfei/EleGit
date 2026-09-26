import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/book_reader_prefs.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/utils/book_markdown_markup.dart';
import 'package:wenxiang/utils/book_reader_markdown_style.dart';
import 'package:wenxiang/widgets/book_markdown_body.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

import 'support/fake_api.dart';

void main() {
  test('promotes leftover html code and anchors', () {
    expect(
      normalizeBookMarkdown(
        '见 <a href="https://vuejs.org">官网</a> 与 <code>ref()</code>',
      ),
      '　　见 [官网↗](https://vuejs.org) 与 `ref()`',
    );
    expect(
      normalizeBookMarkdown('<pre><code>const a = 1;</code></pre>'),
      contains('```\nconst a = 1;\n```'),
    );
    final cleaned = normalizeBookMarkdown(
      '<div class="calibre3"><span class="calibre10">像约翰和我这样的普通人。</span></div>\n'
      '<span class="image placeholder" original-image-src="../images/cover.jpg">Cover Image</span>\n'
      '诺亚 <sup><a href="#fn"><span class="image placeholder epub-footnote">译者注</span></a></sup>似的',
    );
    expect(cleaned, contains('　　像约翰和我这样的普通人。'));
    expect(cleaned, contains('![](../images/cover.jpg)'));
    expect(cleaned, contains('诺亚 [注](wx-footnote:${Uri.encodeComponent('译者注')})似的'));
    expect(cleaned, isNot(contains('（译者注）')));
    expect(cleaned, isNot(contains('<span')));
    expect(cleaned, isNot(contains('<div')));
  });

  test('keeps fenced Vue/HTML samples while stripping running-text chrome', () {
    const md = '''
像约翰和我这样的普通人。

```html
<div id="app"><span>{{ title }}</span></div>
```

行内 `<div id="app">` 也要留下。
''';
    final cleaned = normalizeBookMarkdown(md);
    expect(cleaned, contains('```html\n<div id="app"><span>{{ title }}</span></div>\n```'));
    expect(cleaned, contains('`<div id="app">`'));
    expect(cleaned, contains('像约翰和我这样的普通人。'));
  });

  test('strips calibre chrome from chapter titles', () {
    expect(sanitizeBookDisplayTitle('<span class="calibre14">**一**</span>'), '一');
    expect(
      BookChapterEntry.fromJson({
        'index': 4,
        'file': '005.md',
        'title': '<span class="calibre14">**一**</span>',
      }).title,
      '一',
    );
    expect(
      BookTocEntry.fromJson({
        'index': 2,
        'title': '<span id="magic_copyright_title" class="calibre5">**版权信息**</span>',
      }).title,
      '版权信息',
    );
  });

  test('classifies external and in-book links', () {
    expect(bookMarkdownExternalUri('https://vuejs.org/guide'), Uri.parse('https://vuejs.org/guide'));
    expect(bookMarkdownExternalUri('foo.com?a=1'), Uri.parse('https://foo.com?a=1'));
    expect(bookMarkdownExternalUri('../Text/part0000.xhtml#nav_point_0'), isNull);
    expect(bookMarkdownExternalUri('wx-footnote:note'), isNull);

    const chapters = [
      BookChapterEntry(index: 1, file: '002-part0000.md', title: '版权信息', href: 'OEBPS/Text/part0000.xhtml'),
    ];
    expect(
      resolveBookMarkdownChapterLink(
        href: '../Text/part0000.xhtml#nav_point_0',
        text: '前言',
        chapters: chapters,
      ),
      1,
    );
  });

  test('turns headings, lists, and quotes into markdown', () {
    final cleaned = normalizeBookMarkdown(
      '<h1>标题</h1><ul><li>甲</li><li>乙</li></ul><blockquote><p>引用一句。</p></blockquote>',
    );
    expect(cleaned, contains('# 标题'));
    expect(cleaned, contains('- 甲'));
    expect(cleaned, contains('- 乙'));
    expect(cleaned, contains('> 引用一句。'));
    expect(cleaned, isNot(contains('<h1')));
    expect(cleaned, isNot(contains('<li')));
  });

  test('joins prose line breaks and keeps short verse lines', () {
    expect(
      normalizeBookMarkdown('<p>这是一句<br>很长的话，还没说完。</p>'),
      contains('这是一句很长的话，还没说完。'),
    );
    expect(
      normalizeBookMarkdown('<p>这是一句<br>很长的话，还没说完。</p>'),
      isNot(contains('这是一句\n很长')),
    );
    final verse = normalizeBookMarkdown('<p>床前明月光<br>疑是地上霜<br>举头望明月<br>低头思故乡</p>');
    expect(verse, contains('床前明月光  \n疑是地上霜  \n举头望明月  \n低头思故乡'));
  });

  test('splits plain-converter single newlines into paragraphs', () {
    const raw = '# 4\n\n'
        '4\n'
        ' 那名男子来电，是在康晴找一成商量雪穗母亲一事的三天之后。\n'
        ' 男子自称姓笹垣，一成对这个姓氏全然陌生。\n'
        ' “你在哪里？”';
    final cleaned = normalizeBookMarkdown(raw);
    expect(
      cleaned,
      contains('　　那名男子来电，是在康晴找一成商量雪穗母亲一事的三天之后。\n\n　　男子自称姓笹垣，一成对这个姓氏全然陌生。'),
    );
    expect(cleaned, contains('　　“你在哪里？”'));
    expect(cleaned, isNot(contains('之后。\n 男子')));
  });

  test('drops a repeated chapter heading and indents chinese prose', () {
    const body = '# 第一章\n\n正文开始了。';
    expect(omitLeadingChapterHeading(normalizeBookMarkdown(body), '第一章'), contains('正文开始了。'));
    expect(omitLeadingChapterHeading(normalizeBookMarkdown(body), '第一章'), isNot(contains('# 第一章')));
    expect(normalizeBookMarkdown('正文开始了。'), startsWith('　　正文开始了。'));
  });

  test('reader table theme follows paper palette not chat chrome', () {
    final light = ReaderPalette.forMode(ReaderThemeMode.light);
    final reader = bookReaderMarkdownTableTheme(palette: light, fontSize: 19);
    expect(reader.frameFill, isNot(WxMarkdownTableTheme.chat.frameFill));
    expect(reader.bodyInk, light.ink);
    expect(reader.cellFontSize, closeTo(17.1, 0.01));
  });

  test('reader type scale separates headings and quiets links', () {
    final sheet = bookReaderMarkdownStyle(
      theme: wenxiangTheme(),
      palette: ReaderPalette.forMode(ReaderThemeMode.dark),
      settings: const ReaderSettings(),
    );
    expect(sheet.a?.backgroundColor, isNull);
    expect(sheet.tableColumnWidth, isA<IntrinsicColumnWidth>());
    expect(sheet.blockSpacing, greaterThanOrEqualTo(20));
    expect(sheet.h1!.fontSize!, greaterThan(sheet.h2!.fontSize!));
    expect(sheet.h2!.fontSize!, greaterThan(sheet.h3!.fontSize!));
    final chapter = bookReaderChapterStyle(
      palette: ReaderPalette.forMode(ReaderThemeMode.dark),
      settings: const ReaderSettings(),
    );
    expect(chapter.fontSize!, greaterThan(sheet.h1!.fontSize!));
  });

  testWidgets('chapter body is selectable and wide code stays inside the column', (tester) async {
    final sheet = bookReaderMarkdownStyle(
      theme: wenxiangTheme(),
      palette: ReaderPalette.forMode(ReaderThemeMode.dark),
      settings: const ReaderSettings(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 180,
              child: BookMarkdownBody(
                api: FakeWenxiangApi(),
                bookId: 'book',
                chapterFile: '001.md',
                chapterTitle: '第一章',
                data: '# 第一章\n\n正文从这里开始。\n\n```\n${'token' * 20}\n```',
                styleSheet: sheet,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(SelectableText), findsWidgets);
    expect(find.textContaining('正文从这里开始'), findsOneWidget);
    expect(find.textContaining('# 第一章'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal,
      ),
      findsNothing,
    );
    expect(tester.getSize(find.byType(SelectableText).last).width, lessThanOrEqualTo(180));
  });

  testWidgets('a wide table can scroll sideways inside the column', (tester) async {
    final sheet = bookReaderMarkdownStyle(
      theme: wenxiangTheme(),
      palette: ReaderPalette.forMode(ReaderThemeMode.dark),
      settings: const ReaderSettings(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 180,
            child: BookMarkdownBody(
              api: FakeWenxiangApi(),
              bookId: 'book',
              chapterFile: '001.md',
              data: '| 列甲 | 列乙 | 列丙 | 列丁 |\n| --- | --- | --- | --- |\n| 甲 | 乙 | 丙 | 丁 |',
              styleSheet: sheet,
              tableTheme: bookReaderMarkdownTableTheme(
                palette: ReaderPalette.forMode(ReaderThemeMode.dark),
                fontSize: 19,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('列甲'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal,
      ),
      findsOneWidget,
    );
    final scroll = find.byWidgetPredicate(
      (widget) => widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal,
    );
    expect(tester.getSize(scroll).width, lessThanOrEqualTo(180));
  });

  testWidgets('问书正文铺到屏幕宽度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sheet = bookReaderMarkdownStyle(
      theme: wenxiangTheme(),
      palette: ReaderPalette.forMode(ReaderThemeMode.dark),
      settings: const ReaderSettings(),
    );
    const prose = '这是一段很长的问书正文，应该铺满屏幕宽度，不要在右边留出一大块空白。';
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              BookMarkdownBody(
                api: FakeWenxiangApi(),
                bookId: 'book',
                chapterFile: '001.md',
                data: prose * 3,
                styleSheet: sheet,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final rect = tester.getRect(find.textContaining('铺满屏幕宽度'));
    expect(rect.left, lessThan(20));
    expect(rect.right, greaterThan(360));
  });
}
