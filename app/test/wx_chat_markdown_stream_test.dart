import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/wx_chat_markdown_stream.dart';

void main() {
  group('ChatMarkdownBlockParser', () {
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
  });
}
