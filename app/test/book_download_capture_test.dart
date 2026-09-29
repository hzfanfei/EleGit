import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/book_download_capture.dart';

void main() {
  test('captures annas fast_download only on annas host', () {
    expect(
      shouldCaptureBookDownloadUrl(
        Uri.parse('https://annas-archive.gl/fast_download/f87448722f0072549206b63999ec39e1/0/0'),
      ),
      isTrue,
    );
    expect(
      shouldCaptureBookDownloadUrl(
        Uri.parse('https://libgen.li/get.php?md5=f87448722f0072549206b63999ec39e1&key=ABCDEF'),
      ),
      isFalse,
    );
  });

  test('captures epub path on annas host, skips md5 detail page', () {
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
      isFalse,
    );
    expect(
      shouldCaptureBookDownloadUrl(
        Uri.parse('https://annas-archive.gl/dyn/files/demo.epub'),
      ),
      isTrue,
    );
  });

  test('passes annas download url unchanged to server', () {
    final uri = Uri.parse(
      'https://annas-archive.gl/fast_download/f87448722f0072549206b63999ec39e1/0/0',
    );
    expect(bookDownloadUrlForServer(uri), uri.toString());
  });

  test('annas search url builder', () {
    expect(annasArchiveStartUrl(), 'https://annas-archive.gl');
    expect(
      annasArchiveStartUrl(query: '三体'),
      'https://annas-archive.gl/search?q=%E4%B8%89%E4%BD%93&ext=epub',
    );
  });
}
