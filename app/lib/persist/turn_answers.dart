import '../models.dart';
import '../utils/task_completion.dart';

String stripTaskMarker(String text) => parseTaskCompletion(text).text;

bool _isReplyFragment(String fragment, String full) {
  if (fragment.isEmpty) return true;
  return full.startsWith(fragment) ||
      full.endsWith(fragment) ||
      // Legacy notices can contain only the first few characters of the final
      // paragraph, while the stream also contains preceding progress text.
      full.split('\n').any((line) => line.trimLeft().startsWith(fragment));
}

/// Merge snapshots of one answer without crossing the next user message.
/// Keep distinct assistant messages and the longest version of each snapshot.
bool insertTurnAnswer(List<ChatMessage> messages, int userAt, String text) {
  final clean = stripTaskMarker(text);
  if (clean.isEmpty) return false;
  var insertAt = userAt + 1;
  ChatMessage? reply;
  var changed = false;
  while (insertAt < messages.length && messages[insertAt].role != 'user') {
    final message = messages[insertAt];
    final saved = stripTaskMarker(message.content);
    final full = reply == null ? clean : stripTaskMarker(reply.content);
    if (message.role == 'assistant' &&
        (_isReplyFragment(saved, full) || _isReplyFragment(full, saved))) {
      if (reply == null) {
        reply = message;
        final longest = clean.length > saved.length ? clean : saved;
        if (message.content != longest) {
          message.content = longest;
          changed = true;
        }
      } else {
        if (saved.length > full.length) reply.content = saved;
        messages.removeAt(insertAt);
        changed = true;
        continue;
      }
    }
    insertAt++;
  }
  if (reply != null) return changed;
  messages.insert(
      insertAt, ChatMessage(role: 'assistant', content: clean, engine: 'acp'));
  return true;
}

/// Repair legacy stored rows even if their inbox notification has expired.
List<ChatMessage> restoreTurnAnswers(List<ChatMessage> messages) {
  final restored = <ChatMessage>[];
  for (final message in messages) {
    if (message.role == 'assistant') {
      message.content = stripTaskMarker(message.content);
      if (message.content.isEmpty) continue;
    }
    restored.add(message);
  }
  for (var i = 0; i < restored.length; i++) {
    if (restored[i].role != 'user') continue;
    final answers = restored
        .skip(i + 1)
        .takeWhile((message) => message.role != 'user')
        .where((message) => message.role == 'assistant')
        .toList();
    for (final answer in answers) {
      insertTurnAnswer(restored, i, answer.content);
    }
  }
  return restored;
}
