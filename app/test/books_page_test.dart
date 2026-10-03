import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/book_reading_progress.dart';
import 'package:wenxiang/screens/books_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

BookItem _book(String id, String title) {
  return BookItem(
    id: id,
    filename: '$id.epub',
    title: title,
    author: '',
    language: 'zh',
    size: 1000,
    modifiedAt: '2026-09-15T00:00:00Z',
    hasCover: false,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('books grid renders titles', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = FakeWenxiangApi(
      booksResult: [
        BookItem(
          id: 'demo',
          filename: 'demo.epub',
          title: '演示书',
          author: '作者',
          language: 'zh',
          size: 1000,
          modifiedAt: '2026-09-15T00:00:00Z',
          hasCover: false,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: BooksPage(
          api: api,
          onBack: () {},
          onRead: (_, {expandAsk = false}) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('问书'), findsOneWidget);
    expect(find.text('演示书'), findsOneWidget);
    expect(find.text('作者'), findsOneWidget);
    expect(find.byTooltip('删除'), findsOneWidget);
  });

  testWidgets('newest opened book is listed first', (tester) async {
    SharedPreferences.setMockInitialValues({
      'wx.bookOpened.old': '2026-10-01T01:00:00.000Z',
      'wx.bookOpened.fresh': '2026-10-03T01:00:00.000Z',
    });
    final prefs = await SharedPreferences.getInstance();
    final api = FakeWenxiangApi(
      booksResult: [
        _book('never', '没打开过'),
        _book('old', '较早打开'),
        _book('fresh', '最近打开'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: BooksPage(
          api: api,
          prefs: prefs,
          onBack: () {},
          onRead: (_, {expandAsk = false}) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final titles = tester
        .widgetList<Text>(find.descendant(
          of: find.byType(GridView),
          matching: find.byType(Text),
        ))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    expect(titles.take(2), ['最近打开', '较早打开']);
    await tester.scrollUntilVisible(find.text('没打开过'), 400);
    expect(find.text('没打开过'), findsOneWidget);
    expect(BookReadingProgress(prefs).openedAt('fresh'), isNotNull);
  });
}
