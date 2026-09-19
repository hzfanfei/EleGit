import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';

void main() {
  test('ask sheet steps up hidden → two-thirds → full', () {
    expect(stepAskSheetUp(BookAskSheetLevel.hidden), BookAskSheetLevel.half);
    expect(stepAskSheetUp(BookAskSheetLevel.half), BookAskSheetLevel.full);
    expect(stepAskSheetUp(BookAskSheetLevel.full), BookAskSheetLevel.full);
  });

  test('ask sheet steps down full → two-thirds → hidden', () {
    expect(stepAskSheetDown(BookAskSheetLevel.full), BookAskSheetLevel.half);
    expect(stepAskSheetDown(BookAskSheetLevel.half), BookAskSheetLevel.hidden);
    expect(stepAskSheetDown(BookAskSheetLevel.hidden), BookAskSheetLevel.hidden);
  });

  test('two-thirds fraction is about 0.667', () {
    expect(kBookAskHalfFraction, closeTo(2 / 3, 0.001));
  });
}
