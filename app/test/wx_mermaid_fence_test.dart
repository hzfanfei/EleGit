import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/wx_mermaid_fence.dart';

void main() {
  test('splitMarkdownByMermaidFences forces prose before and after', () {
    const block = '上文\n```mermaid\ngraph TD\n  A-->B\n```\n下文\n';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.length, 3);
    expect(segs[1].isMermaid, isTrue);
    expect(segs[1].mermaidClosed, isTrue);
  });
}
