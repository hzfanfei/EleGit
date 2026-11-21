const taskCompletionMarker = '===TASK_COMPLETED===';

class TaskCompletionText {
  const TaskCompletionText(this.text, this.completed);

  final String text;
  final bool completed;
}

/// Control markers may follow progress paragraphs or touch the final answer.
/// Fenced code and inline examples are ordinary content, not task status.
TaskCompletionText parseTaskCompletion(String source) {
  if (!source.contains(taskCompletionMarker)) {
    return TaskCompletionText(source.trim(), false);
  }
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
    String? inlineFence;
    lines[i] = lines[i].replaceAllMapped(
        RegExp(r'(`+)|===TASK_COMPLETED==='), (token) {
      final ticks = token.group(1);
      if (ticks != null) {
        if (inlineFence == null) {
          inlineFence = ticks;
        } else if (inlineFence == ticks) {
          inlineFence = null;
        }
      } else if (inlineFence == null) {
        completed = true;
        // A missing boundary must not glue progress to the final answer.
        return token.start == 0 ||
                lines[i].substring(0, token.start).trim().isEmpty
            ? ''
            : '\n\n';
      }
      return token.group(0)!;
    });
    if (trimmed.startsWith(taskCompletionMarker)) {
      lines[i] = lines[i].trimLeft();
    }
  }
  return TaskCompletionText(lines.join('\n').trim(), completed);
}
