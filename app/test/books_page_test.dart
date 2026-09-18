import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/book_local.dart';
import 'package:wenxiang/screens/books_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('books grid renders titles', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
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
          bookStore: BookLocalStore(prefs),
          onBack: () {},
          onAsk: (_) {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('问书'), findsOneWidget);
    expect(find.text('演示书'), findsOneWidget);
    expect(find.text('作者'), findsOneWidget);
  });
}
