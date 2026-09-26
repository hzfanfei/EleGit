import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'app_memory.dart';
import 'book_chat_store.dart';

/// Bumps when a notification has been written into a saved chat.
final ValueNotifier<int> chatBackfillTick = ValueNotifier<int>(0);

String stripTaskMarker(String text) {
  return text.replaceFirst(RegExp(r'^===TASK_COMPLETED===\s*', multiLine: true), '').trim();
}

bool sameChatText(String a, String b) => stripTaskMarker(a) == stripTaskMarker(b);

/// Append a finished answer into the saved repo or book chat.
/// Returns true when a transcript changed.
Future<bool> backfillChatFromNotice({
  required String sessionId,
  required String answer,
  String question = '',
  String owner = '',
  String repo = '',
  String bookId = '',
}) async {
  final text = stripTaskMarker(answer);
  final id = sessionId.trim();
  if (text.isEmpty || id.isEmpty) return false;
  final prefs = await SharedPreferences.getInstance();
  final wrote = bookId.trim().isNotEmpty
      ? await _backfillBook(prefs, bookId.trim(), id, question.trim(), text)
      : await _backfillRepo(prefs, owner.trim(), repo.trim(), id, question.trim(), text);
  if (wrote) chatBackfillTick.value = chatBackfillTick.value + 1;
  return wrote;
}

Future<bool> _backfillRepo(
  SharedPreferences prefs,
  String owner,
  String repo,
  String sessionId,
  String question,
  String answer,
) async {
  final memory = AppMemory(prefs);
  final names = <String>[];
  if (owner.isNotEmpty && repo.isNotEmpty) {
    names.add('$owner/$repo');
  } else {
    for (final key in prefs.getKeys()) {
      const prefix = 'wx.chats.';
      if (key.startsWith(prefix)) names.add(key.substring(prefix.length));
    }
  }
  for (final name in names) {
    final store = memory.loadChats(name);
    final known = store.sessions.any((session) => session.id == sessionId) ||
        store.transcripts.containsKey(sessionId);
    if (!known && names.length != 1) continue;
    final next = appendRepoTranscript(
      store,
      sessionId: sessionId,
      answer: answer,
      question: question,
    );
    if (next == null) {
      if (names.length == 1) return false;
      continue;
    }
    await memory.saveChats(name, next);
    return true;
  }
  return false;
}

/// Pure update. Null means the answer is already in that session.
RepoChatStore? appendRepoTranscript(
  RepoChatStore store, {
  required String sessionId,
  required String answer,
  String question = '',
}) {
  final text = stripTaskMarker(answer);
  if (text.isEmpty) return null;
  final list = List<ChatMessage>.from(store.transcripts[sessionId] ?? const []);
  if (list.any((message) => message.role == 'assistant' && sameChatText(message.content, text))) {
    return null;
  }
  if (question.isNotEmpty) {
    ChatMessage? lastUser;
    for (final message in list) {
      if (message.role == 'user') lastUser = message;
    }
    if (lastUser == null || lastUser.content.trim() != question) {
      list.add(ChatMessage(role: 'user', content: question));
    }
  }
  list.add(ChatMessage(role: 'assistant', content: text, engine: 'acp'));
  final transcripts = Map<String, List<ChatMessage>>.from(store.transcripts);
  transcripts[sessionId] = list;
  var sessions = store.sessions;
  if (!sessions.any((session) => session.id == sessionId)) {
    final now = DateTime.now().toUtc().toIso8601String();
    final title = question.isEmpty ? '新会话' : (question.length <= 32 ? question : question.substring(0, 32));
    sessions = [
      ...sessions,
      ChatSession(
        id: sessionId,
        title: title,
        createdAt: now,
        updatedAt: now,
        active: store.activeId == null && sessions.isEmpty,
      ),
    ];
  }
  return RepoChatStore(
    sessions: sessions,
    activeId: store.activeId ?? sessionId,
    transcripts: transcripts,
  );
}

Future<bool> _backfillBook(
  SharedPreferences prefs,
  String bookId,
  String sessionId,
  String question,
  String answer,
) async {
  final memory = AppMemory(prefs);
  final store = memory.loadBookChats(bookId);
  final next = appendBookTranscript(
    store,
    sessionId: sessionId,
    answer: answer,
    question: question,
  );
  if (next == null) return false;
  await memory.saveBookChats(bookId, next);
  return true;
}

BookChatStore? appendBookTranscript(
  BookChatStore store, {
  required String sessionId,
  required String answer,
  String question = '',
}) {
  final text = stripTaskMarker(answer);
  if (text.isEmpty) return null;
  if (store.sessionId != null &&
      store.sessionId!.isNotEmpty &&
      store.sessionId != sessionId &&
      store.hasAnyMessages) {
    return null;
  }
  var anchorId = store.activeAnchorId;
  BookAnchorChat? anchor = anchorId == null ? null : store.anchors[anchorId];
  if (anchor == null && store.anchors.isNotEmpty) {
    final sorted = store.anchors.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    anchor = sorted.first;
    anchorId = anchor.id;
  }
  anchorId ??= 'start';
  final list = List<ChatMessage>.from(anchor?.messages ?? const []);
  if (list.any((message) => message.role == 'assistant' && sameChatText(message.content, text))) {
    return null;
  }
  if (question.isNotEmpty) {
    ChatMessage? lastUser;
    for (final message in list) {
      if (message.role == 'user') lastUser = message;
    }
    if (lastUser == null || lastUser.content.trim() != question) {
      list.add(ChatMessage(role: 'user', content: question));
    }
  }
  list.add(ChatMessage(role: 'assistant', content: text, engine: 'acp'));
  final updated = store.upsertAnchorMessages(
    anchorId: anchorId,
    place: anchor?.place ?? const BookReadingPlace(),
    messages: list,
  );
  return BookChatStore(
    sessionId: sessionId,
    activeAnchorId: updated.activeAnchorId,
    anchors: updated.anchors,
  );
}
