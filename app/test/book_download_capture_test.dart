import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/book_download_capture.dart';

void main() {
  test('captures libgen get.php with md5', () {
    final uri = Uri.parse(
      'https://libgen.li/get.php?md5=f87448722f0072549206b63999ec39e1&key=ABCDEF',
    );
    expect(shouldCaptureBookDownloadUrl(uri), isTrue);
  });

  test('captures epub path and skips normal annas md5 page', () {
    expect(
      shouldCaptureBookDownloadUrl(
        Uri.parse('https://annas-archive.org/md5/f87448722f0072549206b63999ec39e1'),
      ),
      isFalse,
    );
    expect(
      shouldCaptureBookDownloadUrl(
        Uri.parse('https://cdn.example.com/books/demo.epub'),
      ),
      isTrue,
    );
  });

  test('normalizes annas fast_download md5-only to libgen ads', () {
    final uri = Uri.parse(
      'https://annas-archive.gl/fast_download/f87448722f0072549206b63999ec39e1/0/0',
    );
    expect(
      bookDownloadUrlForServer(uri),
      'https://libgen.li/ads.php?md5=f87448722f0072549206b63999ec39e1',
    );
  });

  test('annas search url builder', () {
    expect(annasArchiveStartUrl(), 'https://annas-archive.gl');
    expect(
      annasArchiveStartUrl(query: '三体'),
      'https://annas-archive.gl/search?q=%E4%B8%89%E4%BD%93&ext=epub',
    );
  });
}
