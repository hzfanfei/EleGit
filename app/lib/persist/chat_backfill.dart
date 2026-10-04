import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import 'app_memory.dart';
import 'book_chat_store.dart';

/// Bumps when a notification has been written into a saved chat.
final ValueNotifier<int> chatBackfillTick = ValueNotifier<int>(0);

/// Live partial inbox row while a turn is still running (restart backfill).
class InboxProgressHint {
  InboxProgressHint({
    required this.sessionId,
    required this.question,
    this.turnId = '',
    this.activity = '',
    this.answer = '',
  });

  final String sessionId;
  final String question;
  final String turnId;
  final String activity;
  final String answer;
}

final ValueNotifier<InboxProgressHint?> inboxProgressHint =
    ValueNotifier<InboxProgressHint?>(null);

String stripTaskMarker(String text) {
  return text.replaceFirst(RegExp(r'^===TASK_COMPLETED===\s*', multiLine: true), '').trim();
}

bool sameChatText(String a, String b) => stripTaskMarker(a) == stripTaskMarker(b);

/// Assistant text stored on this turn, before the next user message.
String? answerAfterTurn(List<ChatMessage> messages, String turnId) {
  final userAt = indexOfTurn(messages, turnId);
  if (userAt < 0) return null;
  for (var i = userAt + 1; i < messages.length; i++) {
    final message = messages[i];
    if (message.role == 'user') return null;
    if (message.role == 'assistant' && message.content.trim().isNotEmpty) {
      return message.content;
    }
  }
  return null;
}

/// The saved transcript already has an assistant reply after this turn.
bool transcriptAnswersAsk(List<ChatMessage> messages, String askedTurnId) {
  return answerAfterTurn(messages, askedTurnId) != null;
}

/// Newest inbox row for this turn id. Question text is not a match.
Map<String, dynamic>? pickHeldInboxItem(
  List<Map<String, dynamic>> items, {
  required String turnId,
}) {
  final id = turnId.trim();
  if (id.isEmpty) return null;
  for (final item in items) {
    final answer = (item['answer'] ?? '').toString().trim();
    final activity = (item['activity'] ?? '').toString().trim();
    if (answer.isEmpty && activity.isEmpty) continue;
    if (!heldTurnMatchesNotice(
      turnId: (item['turnId'] ?? '').toString(),
      askedTurnId: id,
    )) {
      continue;
    }
    return item;
  }
  return null;
}

/// A held turn takes only the inbox row that carries the same turn id.
bool heldTurnMatchesNotice({
  required String turnId,
  required String askedTurnId,
}) {
  final current = askedTurnId.trim();
  final incoming = turnId.trim();
  if (current.isEmpty || incoming.isEmpty) return false;
  return current == incoming;
}

int indexOfTurn(List<ChatMessage> messages, String turnId) {
  final id = turnId.trim();
  if (id.isEmpty) return -1;
  var found = -1;
  for (var i = 0; i < messages.length; i++) {
    if (messages[i].role == 'user' && (messages[i].turnId ?? '').trim() == id) {
      found = i;
    }
  }
  return found;
}

/// Places [text] after the user message at [userAt]. False when that reply
/// is already stored on this turn.
bool insertTurnAnswer(List<ChatMessage> messages, int userAt, String text) {
  var insertAt = userAt + 1;
  while (insertAt < messages.length && messages[insertAt].role != 'user') {
    final message = messages[insertAt];
    if (message.role == 'assistant' && sameChatText(message.content, text)) {
      return false;
    }
    insertAt++;
  }
  messages.insert(
    insertAt,
    ChatMessage(role: 'assistant', content: text, engine: 'acp'),
  );
  return true;
}

/// Append a finished answer into the saved repo or book chat.
/// Returns true when a transcript changed.
Future<bool> backfillChatFromNotice({
  required String sessionId,
  required String answer,
  String question = '',
  String owner = '',
  String repo = '',
  String bookId = '',
  String turnId = '',
}) async {
  final text = stripTaskMarker(answer);
  final id = sessionId.trim();
  if (text.isEmpty || id.isEmpty) return false;
  final prefs = await SharedPreferences.getInstance();
  final wrote = bookId.trim().isNotEmpty
      ? await _backfillBook(prefs, bookId.trim(), id, question.trim(), text, turnId.trim())
      : await _backfillRepo(prefs, owner.trim(), repo.trim(), id, question.trim(), text, turnId.trim());
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
  String turnId,
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
      turnId: turnId,
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
  String turnId = '',
}) {
  final text = stripTaskMarker(answer);
  if (text.isEmpty) return null;
  final list = List<ChatMessage>.from(store.transcripts[sessionId] ?? const []);
  final id = turnId.trim();
  if (id.isEmpty) return null;
  final userAt = indexOfTurn(list, id);
  if (userAt >= 0) {
    if (!insertTurnAnswer(list, userAt, text)) return null;
  } else {
    if (question.isNotEmpty) {
      list.add(ChatMessage(role: 'user', content: question, turnId: id));
    }
    list.add(ChatMessage(role: 'assistant', content: text, engine: 'acp'));
  }
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
  String turnId,
) async {
  final memory = AppMemory(prefs);
  final store = memory.loadBookChats(bookId);
  final next = appendBookTranscript(
    store,
    sessionId: sessionId,
    answer: answer,
    question: question,
    turnId: turnId,
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
  String turnId = '',
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
  final id = turnId.trim();
  if (id.isEmpty) return null;
  final userAt = indexOfTurn(list, id);
  if (userAt >= 0) {
    if (!insertTurnAnswer(list, userAt, text)) return null;
  } else {
    if (question.isNotEmpty) {
      list.add(ChatMessage(role: 'user', content: question, turnId: id));
    }
    list.add(ChatMessage(role: 'assistant', content: text, engine: 'acp'));
  }
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
