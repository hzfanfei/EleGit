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

  test('```flowchart LR fence is mermaid with header prepended', () {
    const block = '```flowchart LR\n  A-->B\n```\n';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.length, 1);
    expect(segs.single.mermaidCode, 'flowchart LR\n  A-->B');
  });

  test('normalize keeps body when diagram keyword already present', () {
    expect(
      normalizeMermaidFenceSource('flowchart LR', 'flowchart LR\n  A-->B'),
      'flowchart LR\n  A-->B',
    );
  });
}
