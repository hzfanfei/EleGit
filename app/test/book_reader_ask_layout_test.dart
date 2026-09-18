import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/book_reader_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reader dock hugs the input and leaves no empty sheet band', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: BookReaderPage(
            api: FakeWenxiangApi(),
            prefs: prefs,
            memory: AppMemory(prefs),
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
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('第一章'), findsWidgets);
    expect(find.text('正文。'), findsOneWidget);
    expect(find.byType(BookAskPanel), findsOneWidget);

    final panel = tester.getRect(find.byType(BookAskPanel));
    expect(panel.height, lessThan(200));
    expect(panel.bottom, closeTo(844, 0.5));

    final field = tester.getRect(find.byType(TextField));
    expect(panel.bottom - field.bottom, lessThan(55));
    expect(panel.top, greaterThan(844 - 200));
  });

  testWidgets('opening a book stays on the paper, not a blank 正在打开 page', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(top: 47, bottom: 34),
          ),
          child: BookReaderPage(
            api: _SlowManifestApi(),
            prefs: prefs,
            memory: AppMemory(prefs),
            book: BookItem(
              id: 'demo',
              filename: 'demo.epub',
              title: '演示书',
              author: '作者甲',
              language: 'zh',
              size: 1000,
              modifiedAt: '2026-09-15T00:00:00Z',
              hasCover: false,
            ),
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('正在打开…'), findsNothing);
    expect(find.text('演示书'), findsWidgets);
    expect(find.text('正在读取目录…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('第一章'), findsWidgets);
    expect(find.text('正文。'), findsOneWidget);
  });
}

class _SlowManifestApi extends FakeWenxiangApi {
  @override
  Future<BookReadingManifest> fetchBookReadingManifest(String bookId) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return super.fetchBookReadingManifest(bookId);
  }
}
