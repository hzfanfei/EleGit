import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/wx_mermaid_fence.dart';

void main() {
  test('closed mermaid-only block', () {
    const block = '```mermaid\ngraph TD\n  A --> B\n```\n';
    final parsed = parseMermaidFenceBlock(block);
    expect(parsed, isNotNull);
    expect(parsed!.closed, isTrue);
    expect(parsed.code, contains('graph TD'));
  });

  test('open mermaid-only block (streaming)', () {
    const block = '```mermaid\ngraph TD\n  A --> B';
    final parsed = parseMermaidFenceBlock(block);
    expect(parsed, isNotNull);
    expect(parsed!.closed, isFalse);
  });

  test('prose mixed block is not mermaid-only', () {
    const block = '说明\n\n```mermaid\ngraph TD\n```\n';
    expect(parseMermaidFenceBlock(block), isNull);
  });

  test('splitMarkdownByMermaidFences forces prose before and after', () {
    const block = '上文说明\n```mermaid\ngraph TD\n  A-->B\n```\n下文继续\n';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.length, 3);
    expect(segs[0].isMermaid, isFalse);
    expect(segs[1].isMermaid, isTrue);
    expect(segs[2].isMermaid, isFalse);
    expect(segs[0].prose, contains('上文'));
    expect(segs[2].prose, contains('下文'));
  });

  test('indented mermaid opener still splits', () {
    const block = '  ```mermaid\ngraph LR\n  A-->B\n```\n';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.length, 1);
    expect(segs.single.isMermaid, isTrue);
    expect(segs.single.mermaidClosed, isTrue);
  });

  test('expandMarkdownBlockByMermaid yields three stream blocks', () {
    const block = 'A\n```mermaid\ngraph TD\n```\nB\n';
    final parts = expandMarkdownBlockByMermaid(block);
    expect(parts.length, 3);
    expect(parts[0], contains('A'));
    expect(parts[1], contains('```mermaid'));
    expect(parts[2], contains('B'));
  });
}
