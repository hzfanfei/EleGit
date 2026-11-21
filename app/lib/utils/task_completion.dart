import 'markdown_syntax.dart';

const taskCompletionMarker = '===TASK_COMPLETED===';
final _taskTokens = RegExp(
  '${markdownProtectedInline.pattern}'
  r'|(?<ticks>`+)|'
  '$taskCompletionMarker',
);

class TaskCompletionText {
  const TaskCompletionText(this.text, this.completed);

  final String text;
  final bool completed;
}

/// Control markers may follow progress paragraphs or touch the final answer.
/// Code and display formulas can also contain the marker as literal text.
TaskCompletionText parseTaskCompletion(String source, {bool trim = true}) {
  if (!source.contains(taskCompletionMarker)) {
    return TaskCompletionText(trim ? source.trim() : source, false);
  }
  final literals = MarkdownLiteralScanner();
  var completed = false;
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (literals.consume(lines[i])) continue;
    final trimmed = lines[i].trimLeft();
    String? inlineFence;
    lines[i] = lines[i].replaceAllMapped(_taskTokens, (token) {
      final ticks = (token as RegExpMatch).namedGroup('ticks');
      if (ticks != null) {
        if (inlineFence == null) {
          inlineFence = ticks;
        } else if (inlineFence == ticks) {
          inlineFence = null;
        }
      } else if (inlineFence == null && token[0] == taskCompletionMarker) {
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
  final text = lines.join('\n');
  return TaskCompletionText(trim ? text.trim() : text, completed);
}
