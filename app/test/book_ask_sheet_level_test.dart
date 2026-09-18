import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';

void main() {
  test('ask sheet steps up twice then stays full', () {
    expect(stepAskSheetUp(BookAskSheetLevel.dock), BookAskSheetLevel.half);
    expect(stepAskSheetUp(BookAskSheetLevel.half), BookAskSheetLevel.full);
    expect(stepAskSheetUp(BookAskSheetLevel.full), BookAskSheetLevel.full);
  });

  test('ask sheet steps down twice then stays docked', () {
    expect(stepAskSheetDown(BookAskSheetLevel.full), BookAskSheetLevel.half);
    expect(stepAskSheetDown(BookAskSheetLevel.half), BookAskSheetLevel.dock);
    expect(stepAskSheetDown(BookAskSheetLevel.dock), BookAskSheetLevel.dock);
  });
}
