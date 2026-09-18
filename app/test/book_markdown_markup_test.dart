import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/utils/book_markdown_markup.dart';

void main() {
  test('promotes leftover html code and anchors', () {
    expect(
      normalizeBookMarkdown(
        '见 <a href="https://vuejs.org">官网</a> 与 <code>ref()</code>',
      ),
      '见 [官网](https://vuejs.org) 与 `ref()`',
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
    expect(cleaned, contains('像约翰和我这样的普通人。'));
    expect(cleaned, contains('![](../images/cover.jpg)'));
    expect(cleaned, contains('诺亚 （译者注）似的'));
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
}
