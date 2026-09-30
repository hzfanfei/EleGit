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

  test('flattened mermaid fence is split back into a diagram', () {
    const block =
        '下面两张图。**一次提问怎么走完**```mermaidflowchart TD A["手机提问"] --> B["问象服务"] B --> C["作答"] D --> E{"有图吗"} E -->|有| F["画成图片"] G --> H```**下一张**```mermaidsequenceDiagram participant U as用户 participant App as问象 U->>App:发送```';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.where((s) => s.isMermaid).length, 2);
    final flow = segs.firstWhere((s) => s.isMermaid).mermaidCode!;
    expect(flow, contains('flowchart TD'));
    expect(flow, contains('A["手机提问"] --> B["问象服务"]'));
    expect(flow, contains('\nB --> C["作答"]'));
    expect(flow, contains('\nE -->|有| F["画成图片"]'));
    expect(flow, isNot(contains('mermaidflowchart')));
    final seq = segs.lastWhere((s) => s.isMermaid).mermaidCode!;
    expect(seq, contains('sequenceDiagram'));
    expect(seq, contains('\nparticipant App as问象'));
    expect(seq, contains('\nU->>App:发送'));
  });

  test('already multiline mermaid fence is left unchanged', () {
    const block = '```mermaid\nflowchart TD\n  A-->B\n```\n';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.single.mermaidCode, 'flowchart TD\n  A-->B');
  });
}
