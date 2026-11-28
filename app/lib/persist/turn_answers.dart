import '../models.dart';
import '../utils/task_completion.dart';

String stripTaskMarker(String text) => parseTaskCompletion(text).text;

/// Apply a final reply, including clearing a timed-out turn whose answer arrived late.
bool mergeFinalTurnAnswer(
  List<ChatMessage> messages,
  int userAt,
  String text, {
  bool taskCompleted = false,
}) {
  final answer = parseTaskCompletion(text);
  final completed = taskCompleted || answer.completed;
  if (answer.text.isEmpty && !completed) return false;
  final user = messages[userAt];
  final timedOut = user.outcome == ChatTurnOutcome.timedOut;
  if (timedOut) user.outcome = null;
  return insertTurnAnswer(messages, userAt, answer.text,
          taskCompleted: completed) ||
      timedOut;
}

bool _isReplyFragment(String fragment, String full) {
  if (fragment.isEmpty) return true;
  return full.startsWith(fragment) ||
      full.endsWith(fragment) ||
      // Legacy notices can contain only the first few characters of the final
      // paragraph, while the stream also contains preceding progress text.
      full.split('\n').any((line) => line.trimLeft().startsWith(fragment));
}

final _paragraphGap = RegExp(r'[ \r\n]+');
final _wordCharacter = RegExp(r'\w');
// Line breaks in code, lists, tables and other Markdown blocks carry meaning.
final _structuredText = RegExp(
  r'`|^([ \t]|#{1,6} |>|\||~~~|[-+*] |\d+[.)] |\$\$|\\\[)',
  multiLine: true,
);

bool _sameProseWithDifferentBreaks(String a, String b) {
  if (!a.contains('\n') && !b.contains('\n')) return false;
  if (_structuredText.hasMatch(a) || _structuredText.hasMatch(b)) return false;
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a.codeUnitAt(i) == b.codeUnitAt(j)) {
      i++;
      j++;
      continue;
    }
    final left = _paragraphGap.matchAsPrefix(a, i);
    final right = _paragraphGap.matchAsPrefix(b, j);
    if (!(left?[0]?.contains('\n') ?? false) &&
        !(right?[0]?.contains('\n') ?? false)) {
      return false;
    }
    // Removing a break between Latin words could turn "New York" into "NewYork".
    if (left == null || right == null) {
      final joined = left == null ? a : b;
      final at = left == null ? i : j;
      if (at > 0 && _wordCharacter.hasMatch(joined[at - 1]) &&
          _wordCharacter.hasMatch(joined[at])) {
        return false;
      }
    }
    i = left?.end ?? i;
    j = right?.end ?? j;
  }
  return i == a.length && j == b.length;
}

/// Merge snapshots of one answer without crossing the next user message.
/// Keep distinct assistant messages and the longest version of each snapshot.
bool insertTurnAnswer(
  List<ChatMessage> messages,
  int userAt,
  String text, {
  bool taskCompleted = false,
}) {
  final answer = parseTaskCompletion(text);
  final clean = answer.text;
  final completed = taskCompleted || answer.completed;
  if (clean.isEmpty && !completed) return false;
  var insertAt = userAt + 1;
  ChatMessage? reply;
  var changed = false;
  while (insertAt < messages.length && messages[insertAt].role != 'user') {
    final message = messages[insertAt];
    final parsed = parseTaskCompletion(message.content);
    final saved = parsed.text;
    final full = reply == null ? clean : stripTaskMarker(reply.content);
    if (message.role == 'assistant' &&
        (_isReplyFragment(saved, full) ||
            _isReplyFragment(full, saved) ||
            _sameProseWithDifferentBreaks(saved, full))) {
      if (reply == null) {
        reply = message;
        final longest = clean.length > saved.length ? clean : saved;
        if (message.content != longest) {
          message.content = longest;
          changed = true;
        }
        if (!message.taskCompleted && (completed || parsed.completed)) {
          message.taskCompleted = true;
          changed = true;
        }
      } else {
        if (saved.length > full.length) reply.content = saved;
        reply.taskCompleted |= message.taskCompleted || parsed.completed;
        messages.removeAt(insertAt);
        changed = true;
        continue;
      }
    }
    insertAt++;
  }
  if (reply != null) return changed;
  messages.insert(
      insertAt,
      ChatMessage(
        role: 'assistant',
        content: clean,
        engine: 'acp',
        taskCompleted: completed,
      ));
  return true;
}

/// Repair legacy stored rows even if their inbox notification has expired.
List<ChatMessage> restoreTurnAnswers(List<ChatMessage> messages) {
  final restored = <ChatMessage>[];
  for (final message in messages) {
    if (message.role == 'assistant') {
      final answer = parseTaskCompletion(message.content);
      message.content = answer.text;
      message.taskCompleted |= answer.completed;
      if (message.content.isEmpty && !message.taskCompleted) continue;
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
      insertTurnAnswer(restored, i, answer.content,
          taskCompleted: answer.taskCompleted);
    }
  }
  return restored;
}
