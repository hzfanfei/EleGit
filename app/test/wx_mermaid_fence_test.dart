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
}
