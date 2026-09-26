import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/persist/book_reader_prefs.dart';
import 'package:wenxiang/screens/book_reader_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/book_ask_panel.dart';
import 'package:wenxiang/widgets/book_reader_chrome.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reader ask sheet starts hidden with a bottom peek handle', (tester) async {
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
    final titleTop = tester.getTopLeft(find.text('第一章').first).dy;
    final chromeBottom = tester.getRect(find.byType(BookReaderChrome)).bottom;
    expect(titleTop - chromeBottom, inInclusiveRange(-0.5, 6));
    expect(find.byType(BookAskPanel), findsOneWidget);

    final hiddenPanel = tester.getRect(find.byType(BookAskPanel));
    final hiddenH = BookAskPanel.estimatedHiddenHeight(
      const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34)),
    );
    expect(hiddenPanel.height, closeTo(hiddenH, 1));
    expect(hiddenPanel.bottom, closeTo(844, 0.5));
    expect(find.text('问这段内容…'), findsNothing);

    await tester.tapAt(Offset(hiddenPanel.center.dx, hiddenPanel.top + 12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.text('问这段内容…'), findsOneWidget);
    final expandedPanel = tester.getRect(find.byType(BookAskPanel));
    expect(expandedPanel.height, closeTo(844 * kBookAskHalfFraction, 8));
  });

  test('expanded ask height with keyboard fits in viewport', () {
    const h = 844.0;
    const keyboard = 320.0;
    final layoutHeight = h - keyboard;
    final panelH = layoutHeight * kBookAskHalfFraction;
    expect(panelH + keyboard, lessThanOrEqualTo(h + 0.01));
    expect(layoutHeight * kBookAskFullFraction + keyboard, lessThanOrEqualTo(h + 0.01));
  });

  test('collapse reserve ignores a stale half-sheet measurement', () {
    const media = MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34));
    final dock = BookAskPanel.estimatedDockHeight(media);
    final staleHalf = 844 * kBookAskHalfFraction;

    expect(
      bookReaderAskReserve(
        level: BookAskSheetLevel.dock,
        viewportHeight: 844,
        estimatedDockHeight: dock,
        measuredHeight: staleHalf,
      ),
      dock,
    );
    expect(
      bookReaderAskReserve(
        level: BookAskSheetLevel.half,
        viewportHeight: 844,
        estimatedDockHeight: dock,
        measuredHeight: 0,
      ),
      844 * kBookAskHalfFraction,
    );
    expect(
      bookReaderAskReserve(
        level: BookAskSheetLevel.hidden,
        viewportHeight: 844,
        estimatedDockHeight: dock,
        measuredHeight: dock,
        estimatedHiddenHeight: BookAskPanel.estimatedHiddenHeight(media),
      ),
      BookAskPanel.estimatedHiddenHeight(media),
    );
    expect(
      bookReaderAskReserve(
        level: BookAskSheetLevel.dock,
        viewportHeight: 844,
        estimatedDockHeight: dock,
        measuredHeight: BookAskPanel.estimatedHiddenHeight(media),
        estimatedHiddenHeight: BookAskPanel.estimatedHiddenHeight(media),
      ),
      dock,
    );
  });

  testWidgets('collapsing the ask sheet lets the book fill the gap on the next frame', (tester) async {
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
            expandAsk: true,
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

    final expandedPanel = tester.getRect(find.byType(BookAskPanel));
    expect(expandedPanel.height, closeTo(844 * kBookAskHalfFraction, 12));

    final expandedBook = tester.getRect(find.byKey(const Key('book-reader-body')));
    expect(expandedBook.bottom, lessThan(844 - 250));

    final panel = tester.getRect(find.byType(BookAskPanel));
    await tester.tapAt(Offset(panel.center.dx, panel.top + 18));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    final hiddenBook = tester.getRect(find.byKey(const Key('book-reader-body')));
    expect(hiddenBook.bottom, greaterThan(expandedBook.bottom + 20));
    expect(find.text('问这段内容…'), findsNothing);

    final peek = tester.getRect(find.byType(BookAskPanel));
    await tester.tapAt(Offset(peek.center.dx, peek.top + 12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.text('问这段内容…'), findsOneWidget);
    final halfPanel = tester.getRect(find.byType(BookAskPanel));
    expect(halfPanel.height, closeTo(844 * kBookAskHalfFraction, 12));
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

  testWidgets('ask + keyboard paths keep the sheet on screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    Future<void> pumpReader({
      required double keyboard,
      required bool expandAsk,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: wenxiangTheme(),
          home: MediaQuery(
            data: _readerMedia(keyboard: keyboard),
            child: BookReaderPage(
              api: FakeWenxiangApi(),
              prefs: prefs,
              memory: AppMemory(prefs),
              expandAsk: expandAsk,
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
    }

    void expectSheetAboveKeyboard(double keyboard) {
      final panel = tester.getRect(find.byType(BookAskPanel));
      expect(panel.top, greaterThanOrEqualTo(-0.5));
      expect(panel.bottom, closeTo(844 - keyboard, 1.5));
    }

    await pumpReader(keyboard: 0, expandAsk: true);
    expect(find.text('问这段内容…'), findsOneWidget);
    expectSheetAboveKeyboard(0);
    expect(
      tester.getRect(find.byType(BookAskPanel)).height,
      closeTo(844 * kBookAskHalfFraction, 12),
    );

    await pumpReader(keyboard: 320, expandAsk: true);
    expect(find.byType(TextField), findsOneWidget);
    expectSheetAboveKeyboard(320);
    expect(
      tester.getRect(find.byType(BookAskPanel)).height,
      closeTo((844 - 320) * kBookAskHalfFraction, 12),
    );

    final halfTop = tester.getRect(find.byType(BookAskPanel)).top + 18;
    await tester.tapAt(Offset(195, halfTop));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.text('问这段内容…'), findsNothing);
    expectSheetAboveKeyboard(320);

    await pumpReader(keyboard: 0, expandAsk: false);
    expect(find.text('问这段内容…'), findsNothing);
    await tester.tap(find.byKey(const Key('book-reader-body')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final peek = tester.getRect(find.byType(BookAskPanel));
    await tester.tapAt(Offset(peek.center.dx, peek.top + 12));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));
    expect(find.text('问这段内容…'), findsOneWidget);

    await pumpReader(keyboard: 320, expandAsk: true);
    expectSheetAboveKeyboard(320);
    await pumpReader(keyboard: 0, expandAsk: true);
    expectSheetAboveKeyboard(0);
    expect(
      tester.getRect(find.byType(BookAskPanel)).height,
      closeTo(844 * kBookAskHalfFraction, 12),
    );
  });

  test('status-bar style matches paper and disables OEM contrast scrim', () {
    for (final theme in ReaderThemeMode.values) {
      final settings = ReaderSettings(theme: theme);
      final style = bookReaderSystemOverlayStyle(settings);
      expect(style.statusBarColor, settings.palette.paper);
      expect(style.systemStatusBarContrastEnforced, isFalse);
      expect(style.systemNavigationBarContrastEnforced, isFalse);
    }
  });

  testWidgets('toggling the reader chrome does not move the chapter', (tester) async {
    await _pumpBookReader(tester, expandAsk: false);
    final before = tester.getTopLeft(find.text('第一章').first).dy;
    final body = tester.getRect(find.byKey(const Key('book-reader-body')));
    await tester.tapAt(Offset(body.center.dx, body.top + 80));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.getTopLeft(find.text('第一章').first).dy, closeTo(before, 0.5));
  });

  test('chrome top inset keeps viewPadding while IME zeros padding.top', () {
    const ime = MediaQueryData(
      size: Size(390, 844),
      padding: EdgeInsets.only(top: 0),
      viewPadding: EdgeInsets.only(top: 47, bottom: 34),
      viewInsets: EdgeInsets.only(bottom: 320),
    );
    expect(bookReaderTopContentPad(media: ime), closeTo(47 + kReaderChromeBodyHeight, 0.1));
  });

  testWidgets('immersive sepia + 3/4 + keyboard collapse keeps paper under the status bar', (tester) async {
    await _pumpBookReader(
      tester,
      expandAsk: true,
      keyboard: 320,
      theme: ReaderThemeMode.sepia,
    );

    final paper = ReaderPalette.forMode(ReaderThemeMode.sepia).paper;
    expect(_overlayStyle(tester).statusBarColor, paper);
    expect(_overlayStyle(tester).systemStatusBarContrastEnforced, isFalse);

    expect(tester.getRect(find.byKey(const Key('book-reader-body'))).top, closeTo(0, 0.5));
    expect(tester.getRect(find.byType(BookAskPanel)).bottom, closeTo(844 - 320, 1.5));

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 220));
    expect(_overlayStyle(tester).statusBarColor, paper);

    final immersiveBody = tester.getRect(find.byKey(const Key('book-reader-body')));
    expect(immersiveBody.top, closeTo(0, 0.5));
    await tester.tapAt(immersiveBody.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('问这段内容…'), findsNothing, reason: 'scrim tap collapses 3/4 ask');
    expect(tester.getRect(find.byKey(const Key('book-reader-body'))).top, closeTo(0, 0.5));
    expect(tester.getRect(find.byType(BookAskPanel)).bottom, closeTo(844 - 320, 1.5));
    expect(_overlayStyle(tester).statusBarColor, paper);
  });

  testWidgets('full ask sheet hides the voice FAB so it cannot sit in the status bar', (tester) async {
    await _pumpBookReader(tester, expandAsk: true, keyboard: 0);

    expect(find.byKey(const Key('wx-quick-voice-mic')), findsOneWidget);
    final halfFab = tester.getRect(find.byKey(const Key('wx-quick-voice-mic')));
    expect(halfFab.top, greaterThan(80));

    final panel = tester.getRect(find.byType(BookAskPanel));
    await tester.flingFrom(Offset(panel.center.dx, panel.top + 18), const Offset(0, -90), 700);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 320));

    expect(find.text('问这段内容…'), findsOneWidget);
    expect(tester.getRect(find.byType(BookAskPanel)).top, closeTo(0, 2));
    expect(find.byKey(const Key('wx-quick-voice-mic')), findsNothing);
  });

  testWidgets('3/4 ask + keyboard hides the voice FAB in the remaining reader strip', (tester) async {
    await _pumpBookReader(tester, expandAsk: true, keyboard: 320);
    expect(find.text('问这段内容…'), findsOneWidget);
    expect(find.byKey(const Key('wx-quick-voice-mic')), findsNothing);
  });

  testWidgets('settings and TOC dismiss the ask keyboard before covering the reader', (tester) async {
    await _pumpBookReader(tester, expandAsk: true, keyboard: 0);

    await tester.showKeyboard(find.byType(TextField));
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('阅读设置'), findsOneWidget);
    expect(tester.testTextInput.hasAnyClients, isFalse);

    await tester.tapAt(const Offset(24, 24));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.showKeyboard(find.byType(TextField));
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await tester.tap(find.byTooltip('目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('目录'), findsOneWidget);
    expect(tester.testTextInput.hasAnyClients, isFalse);
  });

  testWidgets('light reader theme keeps a paper status bar with the keyboard open', (tester) async {
    await _pumpBookReader(tester, expandAsk: true, keyboard: 320, theme: ReaderThemeMode.light);
    expect(_overlayStyle(tester).statusBarColor, ReaderPalette.forMode(ReaderThemeMode.light).paper);
    expect(tester.getRect(find.byKey(const Key('book-reader-body'))).top, closeTo(0, 0.5));
  });
}

SystemUiOverlayStyle _overlayStyle(WidgetTester tester) {
  return tester
      .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      )
      .value;
}

Future<void> _pumpBookReader(
  WidgetTester tester, {
  required bool expandAsk,
  double keyboard = 0,
  ReaderThemeMode theme = ReaderThemeMode.dark,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({
    'wx.readerSettings': jsonEncode(ReaderSettings(theme: theme).toJson()),
  });
  final prefs = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    MaterialApp(
      theme: wenxiangTheme().copyWith(splashFactory: NoSplash.splashFactory),
      home: MediaQuery(
        data: _readerMedia(keyboard: keyboard),
        child: BookReaderPage(
          api: FakeWenxiangApi(),
          prefs: prefs,
          memory: AppMemory(prefs),
          expandAsk: expandAsk,
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
}

MediaQueryData _readerMedia({double keyboard = 0}) {
  return MediaQueryData(
    size: const Size(390, 844),
    padding: EdgeInsets.only(top: 47, bottom: keyboard > 0 ? 0 : 34),
    viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
    viewInsets: EdgeInsets.only(bottom: keyboard),
  );
}

class _SlowManifestApi extends FakeWenxiangApi {
  @override
  Future<BookReadingManifest> fetchBookReadingManifest(String bookId) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return super.fetchBookReadingManifest(bookId);
  }
}
