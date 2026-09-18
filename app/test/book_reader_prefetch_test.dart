import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/book_reader_prefetch.dart';

void main() {
  test('appends early, not only at the last 360px', () {
    expect(
      readerShouldAppendNext(
        pixels: 2000,
        maxExtent: 3200,
        rangeLast: 0,
        chapterCount: 5,
      ),
      isTrue,
    );
    expect(
      readerShouldAppendNext(
        pixels: 100,
        maxExtent: 3200,
        rangeLast: 0,
        chapterCount: 5,
      ),
      isFalse,
    );
    expect(
      readerShouldAppendNext(
        pixels: 0,
        maxExtent: 0,
        rangeLast: 0,
        chapterCount: 5,
      ),
      isTrue,
    );
    expect(
      readerShouldAppendNext(
        pixels: 10,
        maxExtent: 10,
        rangeLast: 4,
        chapterCount: 5,
      ),
      isFalse,
    );
  });

  test('prefetch targets are the next two chapters', () {
    expect(
      readerPrefetchTargets(rangeLast: 0, chapterCount: 6),
      [1, 2],
    );
    expect(
      readerPrefetchTargets(rangeLast: 4, chapterCount: 6),
      [5],
    );
    expect(
      readerPrefetchTargets(rangeLast: 5, chapterCount: 6),
      isEmpty,
    );
  });
}
