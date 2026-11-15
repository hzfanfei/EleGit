import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/task_completion.dart';

void main() {
  test('completion is detected after progress with or without a newline', () {
    for (final separator in ['', '\n', '\r\n']) {
      final result =
          parseTaskCompletion('检查中。\n\n  ===TASK_COMPLETED===$separator已完成。');
      expect(result.completed, isTrue);
      expect(result.text, contains('检查中。'));
      expect(result.text, contains('已完成。'));
      expect(result.text, isNot(contains(taskCompletionMarker)));
    }
  });

  test('code examples do not signal completion or get stripped', () {
    for (final fence in ['```', '~~~~']) {
      final example = '${fence}text\n===TASK_COMPLETED===\n$fence';
      final result = parseTaskCompletion(example);
      expect(result.completed, isFalse);
      expect(result.text, example);
      final completed =
          parseTaskCompletion('$example\n\n===TASK_COMPLETED===真正完成。');
      expect(completed.completed, isTrue);
      expect(completed.text, '$example\n\n真正完成。');
    }
    expect(parseTaskCompletion('示例：`===TASK_COMPLETED===`').completed, isFalse);
  });

  test('multiple control markers produce clean content', () {
    final result = parseTaskCompletion(
        '===TASK_COMPLETED===\n第一项。\n\n===TASK_COMPLETED===第二项。');
    expect(result.completed, isTrue);
    expect(result.text, '第一项。\n\n第二项。');
  });
}
