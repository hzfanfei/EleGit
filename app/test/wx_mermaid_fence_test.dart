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

  test('flattened class, pie, and er diagrams are split into statements', () {
    const block =
        '**类图**```mermaidclassDiagram class Answer { +文本 +有图() } class Diagram { +类型 +显示() } Answer --> Diagram: 包含```'
        '**饼图**```mermaidpie showData title 回答里的内容 "文字" : 70 "流程图" : 20 "其他图" : 10```'
        '**关系图**```mermaiderDiagram ANSWER ||--o{ DIAGRAM : 包含 ANSWER { string文本 } DIAGRAM { string类型 }```';
    final segs = splitMarkdownByMermaidFences(block).where((s) => s.isMermaid).toList();
    expect(segs, hasLength(3));

    final klass = segs[0].mermaidCode!;
    expect(klass, contains('classDiagram'));
    expect(klass, contains('class Answer {\n+文本\n+有图()'));
    expect(klass, contains('class Diagram {\n+类型\n+显示()'));
    expect(klass, contains('\nAnswer --> Diagram: 包含'));

    final pie = segs[1].mermaidCode!;
    expect(pie, startsWith('pie showData\n'));
    expect(pie, contains('\ntitle 回答里的内容'));
    expect(pie, contains('\n"文字" : 70'));
    expect(pie, contains('\n"流程图" : 20'));
    expect(pie, contains('\n"其他图" : 10'));

    final er = segs[2].mermaidCode!;
    expect(er, contains('erDiagram'));
    expect(er, contains('ANSWER ||--o{ DIAGRAM : 包含'));
    expect(er, contains('ANSWER {\nstring 文本\n}'));
    expect(er, contains('DIAGRAM {\nstring 类型\n}'));
  });

  test('already multiline mermaid fence is left unchanged', () {
    const block = '```mermaid\nflowchart TD\n  A-->B\n```\n';
    final segs = splitMarkdownByMermaidFences(block);
    expect(segs.single.mermaidCode, 'flowchart TD\n  A-->B');
  });
}
