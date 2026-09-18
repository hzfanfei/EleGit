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
