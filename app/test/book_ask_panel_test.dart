import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dock height stays near the composer, not a tall empty sheet', () {
    const media = MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34));
    final dock = BookAskPanel.estimatedDockHeight(media);
    expect(dock, lessThan(200));
    expect(dock, closeTo(8 + 11 + 43 + 60 + 34, 0.1));
  });

  testWidgets('collapsed ask panel has no leftover filler below the input', (tester) async {
    final sheetSize = ValueNotifier<double>(0.16);
    addTearDown(sheetSize.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: BookAskPanel(
                api: FakeWenxiangApi(),
                book: BookItem(
                  id: 'demo',
                  filename: 'demo.epub',
                  title: '演示书',
                  author: '作者',
                  language: 'zh',
                  size: 1000,
                  modifiedAt: '2026-09-15T00:00:00Z',
                  hasCover: false,
                ),
                scrollController: ScrollController(),
                sheetSize: sheetSize,
                expanded: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final panel = tester.getSize(find.byType(BookAskPanel));
    expect(panel.height, lessThan(200));
    expect(panel.height, closeTo(BookAskPanel.estimatedDockHeight(
      const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34)),
    ), 16));
    expect(find.text('问这段内容…'), findsOneWidget);
    expect(find.byType(CustomScrollView), findsNothing);
    final field = tester.getRect(find.byType(TextField));
    final panelRect = tester.getRect(find.byType(BookAskPanel));
    expect(panelRect.bottom - field.bottom, lessThan(55));
  });
}
