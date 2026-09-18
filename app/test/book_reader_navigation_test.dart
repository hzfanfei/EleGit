import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/book_reader_navigation.dart';

void main() {
  test('readerBookProgress includes chapter scroll fraction', () {
    expect(
      readerBookProgress(chapterIndex: 0, chapterCount: 5, chapterScrollFraction: 0.5),
      closeTo(0.125, 0.001),
    );
    expect(
      readerBookProgress(chapterIndex: 4, chapterCount: 5, chapterScrollFraction: 1),
      1.0,
    );
  });

  test('readerCanGoPrev/Next', () {
    expect(readerCanGoPrev(0), false);
    expect(readerCanGoPrev(1), true);
    expect(readerCanGoNext(0, 3), true);
    expect(readerCanGoNext(2, 3), false);
  });
}
