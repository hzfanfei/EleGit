import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/book_markdown_assets.dart';

void main() {
  test('resolves markdown images from chapter and spine paths', () {
    expect(
      resolveBookMarkdownAssetRef(
        src: '../media/abc.png',
        chapterFile: '001-chapter1.md',
      ),
      'media/abc.png',
    );
    expect(
      resolveBookMarkdownAssetRef(
        src: 'fig.png',
        chapterFile: '001-chapter1.md',
        spineHref: 'OEBPS/chapter1.xhtml',
      ),
      'extracted/OEBPS/fig.png',
    );
    expect(
      resolveBookMarkdownAssetRef(
        src: 'https://example.com/a.png',
        chapterFile: '001.md',
      ),
      'https://example.com/a.png',
    );
  });
}
