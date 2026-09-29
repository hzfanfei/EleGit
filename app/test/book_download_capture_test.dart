import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/anna_cookie.dart';
import 'package:wenxiang/utils/anna_device_download.dart';
import 'package:wenxiang/utils/book_download_capture.dart';

void main() {
  test('slow_download gate opens in WebView, not intercepted as binary', () {
    final slow = Uri.parse(
      'https://annas-archive.gl/slow_download/86eb03dc6a6956f90f5e4d51574c99e4/0/1',
    );
    expect(isAnnaSlowDownloadGateUri(slow), isTrue);
    expect(shouldCaptureBookDownloadUrl(slow), isFalse);
    expect(shouldCaptureBookDownloadFromClipboard(slow), isTrue);
  });

  test('annaDownloadUriFromClipboard parses slow link', () {
    final url =
        'https://annas-archive.gl/slow_download/86eb03dc6a6956f90f5e4d51574c99e4/0/1';
    expect(annaDownloadUriFromClipboard(url)?.toString(), url);
    expect(
      annaDownloadUriFromClipboard('链接 $url 请下载')?.toString(),
      url,
    );
  });

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

  test('annaMd5FromDownloadUrl reads slow and fast paths', () {
    expect(
      annaMd5FromDownloadUrl(
        Uri.parse(
          'https://annas-archive.gl/slow_download/0/f87448722f0072549206b63999ec39e1/0/0',
        ),
      ),
      'f87448722f0072549206b63999ec39e1',
    );
    expect(
      annaMd5FromDownloadUrl(
        Uri.parse(
          'https://annas-archive.gl/slow_download/86eb03dc6a6956f90f5e4d51574c99e4/0/1',
        ),
      ),
      '86eb03dc6a6956f90f5e4d51574c99e4',
    );
    expect(
      annaMd5FromDownloadUrl(
        Uri.parse(
          'https://annas-archive.gl/fast_download/f87448722f0072549206b63999ec39e1/0/0',
        ),
      ),
      'f87448722f0072549206b63999ec39e1',
    );
  });

  test('annaCookieLookupUris includes origin and md5 page', () {
    final download = Uri.parse(
      'https://annas-archive.gl/slow_download/0/f87448722f0072549206b63999ec39e1/0/0',
    );
    final uris = annaCookieLookupUris(download).map((u) => u.toString()).toSet();
    expect(uris.contains('https://annas-archive.gl/'), isTrue);
    expect(
      uris.contains(
        'https://annas-archive.gl/md5/f87448722f0072549206b63999ec39e1',
      ),
      isTrue,
    );
  });

  test('mergeAnnaCookieHeader merges set-cookie without dropping prior', () {
    const base = 'a=1; b=2';
    final merged = mergeAnnaCookieHeader(base, ['c=3; Path=/', 'b=9']);
    expect(merged.contains('a=1'), isTrue);
    expect(merged.contains('b=9'), isTrue);
    expect(merged.contains('c=3'), isTrue);
  });

  test('annas search url builder', () {
    expect(annasArchiveStartUrl(), 'https://annas-archive.gl');
    expect(
      annasArchiveStartUrl(query: '三体'),
      'https://annas-archive.gl/search?q=%E4%B8%89%E4%BD%93&ext=epub',
    );
  });
}
