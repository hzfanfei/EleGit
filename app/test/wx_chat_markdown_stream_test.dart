import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/task_completion.dart';
import 'package:wenxiang/utils/text_fit.dart';
import 'package:wenxiang/utils/wx_mermaid_fence.dart';
import 'package:wenxiang/widgets/wx_chat_markdown_stream.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

void main() {
  group('ChatMarkdownBlockParser', () {
    test('tilde and longer fences protect special tags inside code', () {
      for (final fence in ['~~~', '````']) {
        final p = ChatMarkdownBlockParser();
        p.update('$fence\n<details>\n\n> [!NOTE]\n</details>\n$fence\n');
        expect(p.completed, hasLength(1));
        expect(p.completed.single, contains('<details>\n\n> [!NOTE]'));
        expect(p.pending, isEmpty);
      }
    });
    test('treats a single paragraph as one pending block', () {
      final p = ChatMarkdownBlockParser();
      p.update('hello world');
      expect(p.completed, isEmpty);
      expect(p.pending, 'hello world\n');
    });

    test('flushes a block on a blank line', () {
      final p = ChatMarkdownBlockParser();
      p.update('first paragraph\n\nstill typing');
      expect(p.completed, ['first paragraph\n']);
      expect(p.pending, 'still typing\n');
    });

    test('flushes multiple prose blocks separated by blank lines', () {
      final p = ChatMarkdownBlockParser();
      p.update('a\n\nb\n\nc\n');
      expect(p.completed, ['a\n', 'b\n']);
      expect(p.pending, 'c\n');
    });

    test('captures a fenced code block once closed', () {
      final p = ChatMarkdownBlockParser();
      p.update('intro\n\n```dart\nvoid main() {}\n```\n\nafter');
      expect(p.completed, ['intro\n', '```dart\nvoid main() {}\n```\n']);
      expect(p.pending, 'after\n');
    });

    test('keeps an unclosed fence as pending', () {
      final p = ChatMarkdownBlockParser();
      p.update('intro\n\n```dart\nvoid main');
      expect(p.completed, ['intro\n']);
      expect(p.pending, '```dart\nvoid main\n');
    });

    test('incremental updates extend the previous parse', () {
      final p = ChatMarkdownBlockParser();
      p.update('hello');
      expect(p.completed, isEmpty);
      expect(p.pending, 'hello\n');
      p.update('hello world\n\nnext');
      expect(p.completed, ['hello world\n']);
      expect(p.pending, 'next\n');
    });

    test('handles a fence with no language', () {
      final p = ChatMarkdownBlockParser();
      p.update('```\nplain code\n```\n');
      expect(p.completed, hasLength(1));
      expect(p.completed.first, '```\nplain code\n```\n');
    });

    test('handles a heading line as part of a prose block', () {
      final p = ChatMarkdownBlockParser();
      p.update('# Title\n\nbody');
      expect(p.completed, ['# Title\n']);
      expect(p.pending, 'body\n');
    });

    test('handles CRLF line endings', () {
      final p = ChatMarkdownBlockParser();
      p.update('line one\r\n\r\nline two\r\n');
      expect(p.completed, ['line one\n']);
      expect(p.pending, 'line two\n');
    });

    test('handles a trailing blank line by leaving empty pending', () {
      final p = ChatMarkdownBlockParser();
      p.update('block\n\n');
      expect(p.completed, ['block\n']);
      expect(p.pending, '');
    });

    test('keeps table rows together across blank lines from the model', () {
      final p = ChatMarkdownBlockParser();
      p.update('| a | b |\n\n| --- | --- |\n\n| c | d |\n\nafter');
      expect(p.completed, ['| a | b |\n| --- | --- |\n| c | d |\n']);
      expect(p.pending, 'after\n');
    });

    test('flushes table before following prose', () {
      final p = ChatMarkdownBlockParser();
      p.update('| a | b |\n| --- | --- |\n| c | d |\n\nparagraph');
      expect(p.completed, ['| a | b |\n| --- | --- |\n| c | d |\n']);
      expect(p.pending, 'paragraph\n');
    });

    test('reuses settled paragraphs and matches a full parse on appends', () {
      final p = ChatMarkdownBlockParser();
      final prefix = List.generate(120, (i) => '第 $i 段正文。\r\n\r\n').join();
      final response = '$prefix'
          '| head | state |\n\n| --- | --- |\n\n| one | ready |\n\n'
          '<details>\n<summary>展开</summary>\n\n~~~text\n</details>\n~~~\n'
          '正文\n</details>\n\n'
          '\$\$\nabcdefghijklmnop\n\nx = 2\n\$\$\n\n'
          '流程 ```mermaidflowchart TD A --> B``` 结束。\n\n'
          '===TASK_COMPLETED===完成。';
      p.updateSource('$prefix新增段落');
      expect(p.settledSourceLength, prefix.length);
      p.updateSource('$prefix新增段落还在写');
      expect(p.settledSourceLength, prefix.length);
      final baseline = ChatMarkdownBlockParser();
      for (var end = prefix.length; end <= response.length; end++) {
        final raw = response.substring(0, end);
        final task = parseTaskCompletion(raw.replaceAll('\r\n', '\n'));
        final prepared = separateChatParagraphs(
          normalizeChatMarkdownTables(restoreFlattenedMermaidFences(task.text)),
        );
        baseline.update(prepared);
        p.updateSource(raw);
        expect(p.completed, baseline.completed, reason: 'at offset $end');
        expect(p.pending, baseline.pending, reason: 'at offset $end');
        expect(p.taskCompleted, task.completed, reason: 'at offset $end');
      }
      expect(p.settledSourceLength, greaterThan(prefix.length));
      p.updateSource('替换正文');
      expect(p.completed, isEmpty);
      expect(p.pending, '替换正文\n');
      expect(p.taskCompleted, isFalse);
    });
  });
}
