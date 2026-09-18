import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/book_markdown_assets.dart';

void main() {
  test('resolves pandoc media and extracted spine images', () {
    expect(
      bookMarkdownAssetCandidates(
        src: '../media/abc.png',
        chapterFile: '001-chapter1.md',
      ),
      contains('media/abc.png'),
    );
    expect(
      bookMarkdownAssetCandidates(
        src: 'fig.png',
        chapterFile: '001-chapter1.md',
        spineHref: 'OEBPS/chapter1.xhtml',
      ),
      containsAll(['extracted/OEBPS/fig.png', 'extracted/OEBPS/Images/fig.png']),
    );
    expect(
      bookMarkdownAssetCandidates(
        src: '../Images/image00483.jpeg',
        chapterFile: '002-part0000.md',
        spineHref: 'OEBPS/part0000.xhtml',
      ).first,
      'extracted/OEBPS/Images/image00483.jpeg',
    );
    expect(
      resolveBookMarkdownAssetRef(
        src: 'https://example.com/a.png',
        chapterFile: '001.md',
      ),
      'https://example.com/a.png',
    );
    expect(
      promoteBookHtmlImages(
        '<img src="../Images/image00483.jpeg" class="sgc-4" style="width:85.0%" />',
      ),
      '![](../Images/image00483.jpeg)',
    );
  });
}
