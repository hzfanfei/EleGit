const taskCompletionMarker = '===TASK_COMPLETED===';

class TaskCompletionText {
  const TaskCompletionText(this.text, this.completed);

  final String text;
  final bool completed;
}

/// Control markers may follow progress paragraphs or touch the final answer.
/// Fenced code and inline examples are ordinary content, not task status.
TaskCompletionText parseTaskCompletion(String source) {
  String? fence;
  var completed = false;
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trimLeft();
    if (fence != null) {
      final closing = trimmed.trimRight();
      if (closing.length >= fence.length &&
          closing.split('').every((char) => char == fence![0])) {
        fence = null;
      }
      continue;
    }
    final opening = RegExp(r'^(`{3,}|~{3,})').firstMatch(trimmed);
    if (opening != null) {
      fence = opening.group(1);
      continue;
    }
    if (trimmed.startsWith(taskCompletionMarker)) {
      completed = true;
      lines[i] = trimmed.substring(taskCompletionMarker.length).trimLeft();
    }
  }
  return TaskCompletionText(lines.join('\n').trim(), completed);
}
