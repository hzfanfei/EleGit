import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/persist/book_chat_store.dart';
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
    expect(BookAskPanel.estimatedHiddenHeight(media), closeTo(8 + 11 + 34, 0.1));
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

  testWidgets('waiting ask shows intermediate book phases before the first token', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sheetSize = ValueNotifier<double>(0.45);
    addTearDown(sheetSize.dispose);
    final api = FakeWenxiangApi(
      streamPace: const Duration(milliseconds: 80),
      streamEvents: [
        ChatStreamEvent(type: 'status', phase: 'connect'),
        ChatStreamEvent(type: 'status', phase: 'book'),
        ChatStreamEvent(type: 'delta', text: '墙纸是压抑的象征。'),
        ChatStreamEvent(type: 'done', engine: 'acp'),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34)),
          child: Scaffold(
            body: SizedBox(
              height: 520,
              child: BookAskPanel(
                api: api,
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
                expanded: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.enterText(find.byType(TextField), '墙纸象征什么');
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();

    expect(find.text('正在连接问书…'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('正在连接问书…'), findsWidgets);

    await tester.pump(const Duration(milliseconds: 90));
    expect(find.text('对照当前章节…'), findsWidgets);
    expect(find.text('墙纸是压抑的象征。'), findsNothing);

    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('history turns stay collapsed until opened', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final memory = AppMemory(prefs);
    const place = BookReadingPlace(chapter: '第一章');
    await memory.saveBookChats(
      'demo',
      BookChatStore.empty().upsertAnchorMessages(
        anchorId: bookAnchorId(place),
        place: place,
        messages: [
          ChatMessage(role: 'user', content: '墙纸是什么意思？'),
          ChatMessage(role: 'assistant', content: '黄色墙纸象征被困住的精神状态。'),
        ],
      ),
    );

    final sheetSize = ValueNotifier<double>(0.45);
    addTearDown(sheetSize.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(bottom: 34)),
          child: Scaffold(
            body: SizedBox(
              height: 520,
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
                expanded: true,
                memory: memory,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('历史').last);
    await tester.pump();

    expect(find.text('墙纸是什么意思？'), findsOneWidget);
    expect(find.text('黄色墙纸象征被困住的精神状态。'), findsNothing);
    expect(find.byTooltip('展开回答'), findsOneWidget);

    await tester.tap(find.byTooltip('展开回答'));
    await tester.pump();

    expect(find.text('黄色墙纸象征被困住的精神状态。'), findsOneWidget);
    expect(find.byTooltip('收起回答'), findsOneWidget);
  });
}
