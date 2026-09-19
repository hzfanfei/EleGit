import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/persist/book_chat_store.dart';

void main() {
  test('bookAnchorId groups by chapter title', () {
    const a = BookReadingPlace(chapter: '第一章 开端');
    const b = BookReadingPlace(chapter: '第一章 开端', epubCfi: 'epubcfi(/6/4!)');
    const c = BookReadingPlace(chapter: '第二章');
    expect(bookAnchorId(a), bookAnchorId(b));
    expect(bookAnchorId(a), isNot(bookAnchorId(c)));
  });

  test('save and load book chats per anchor', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final memory = AppMemory(prefs);
    const bookId = 'demo_book';

    var store = BookChatStore.empty().upsertAnchorMessages(
      anchorId: bookAnchorId(const BookReadingPlace(chapter: '序章')),
      place: const BookReadingPlace(chapter: '序章', epubCfi: 'cfi-1'),
      messages: [
        ChatMessage(role: 'user', content: '这章讲什么？'),
        ChatMessage(role: 'assistant', content: '介绍背景。'),
      ],
    );
    store = BookChatStore(
      sessionId: 'sess-1',
      activeAnchorId: bookAnchorId(const BookReadingPlace(chapter: '序章')),
      anchors: store.anchors,
    );
    await memory.saveBookChats(bookId, store);

    final loaded = memory.loadBookChats(bookId);
    expect(loaded.sessionId, 'sess-1');
    final anchor = loaded.anchors.values.first;
    expect(anchor.place.chapter, '序章');
    expect(anchor.messages.length, 2);
    expect(loaded.lastAssistantPeek(anchor.id), '介绍背景。');
  });

  test('deleteTurn removes user and replies', () {
    const place = BookReadingPlace(chapter: '第一章');
    final id = bookAnchorId(place);
    var store = BookChatStore.empty().upsertAnchorMessages(
      anchorId: id,
      place: place,
      messages: [
        ChatMessage(role: 'user', content: 'Q1'),
        ChatMessage(role: 'assistant', content: 'A1'),
        ChatMessage(role: 'user', content: 'Q2'),
        ChatMessage(role: 'assistant', content: 'A2'),
      ],
    );
    store = store.deleteTurn(id, 0);
    expect(store.messagesForAnchor(id).length, 2);
    expect(store.messagesForAnchor(id).first.content, 'Q2');
    store = store.deleteTurn(id, 0);
    expect(store.anchors.containsKey(id), isFalse);
  });

  test('ChatMessage via voice round-trips in store json', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final memory = AppMemory(prefs);
    const bookId = 'voice_book';
    const place = BookReadingPlace(chapter: '第三章');
    final id = bookAnchorId(place);
    final store = BookChatStore(
      sessionId: 's1',
      activeAnchorId: id,
      anchors: {
        id: BookAnchorChat(
          id: id,
          place: place,
          updatedAt: '2026-01-01T00:00:00Z',
          messages: [
            ChatMessage(role: 'user', content: '这章啥意思', via: 'voice'),
            ChatMessage(role: 'assistant', content: '讲经理人输出', via: 'voice'),
          ],
        ),
      },
    );
    await memory.saveBookChats(bookId, store);
    final loaded = memory.loadBookChats(bookId);
    final msgs = loaded.messagesForAnchor(id);
    expect(msgs.length, 2);
    expect(msgs.first.via, 'voice');
    expect(msgs.last.content, contains('经理人'));
  });

  test('listAllBookQaTurns spans chapters', () {
    var store = BookChatStore.empty();
    store = store.upsertAnchorMessages(
      anchorId: bookAnchorId(const BookReadingPlace(chapter: 'A')),
      place: const BookReadingPlace(chapter: 'A'),
      messages: [ChatMessage(role: 'user', content: 'a')],
    );
    store = store.upsertAnchorMessages(
      anchorId: bookAnchorId(const BookReadingPlace(chapter: 'B')),
      place: const BookReadingPlace(chapter: 'B'),
      messages: [ChatMessage(role: 'user', content: 'b')],
    );
    final turns = listAllBookQaTurns(store);
    expect(turns.length, 2);
    expect(turns.map((t) => t.chapter).toSet(), {'A', 'B'});
  });
}
