import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';

void main() {
  test('ask sheet steps up hidden → three-quarters → full', () {
    expect(stepAskSheetUp(BookAskSheetLevel.hidden), BookAskSheetLevel.half);
    expect(stepAskSheetUp(BookAskSheetLevel.half), BookAskSheetLevel.full);
    expect(stepAskSheetUp(BookAskSheetLevel.full), BookAskSheetLevel.full);
  });

  test('ask sheet steps down full → three-quarters → hidden', () {
    expect(stepAskSheetDown(BookAskSheetLevel.full), BookAskSheetLevel.half);
    expect(stepAskSheetDown(BookAskSheetLevel.half), BookAskSheetLevel.hidden);
    expect(stepAskSheetDown(BookAskSheetLevel.hidden), BookAskSheetLevel.hidden);
  });

  test('three-quarters fraction is 0.75', () {
    expect(kBookAskHalfFraction, closeTo(3 / 4, 0.001));
  });
}
