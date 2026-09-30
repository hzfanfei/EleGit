import 'package:flutter_mermaid/flutter_mermaid.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/wx_mermaid_normalize.dart';

void main() {
  const parser = MermaidParser();

  test('pie title on same line as pie', () {
    const raw = '''
pie title 仓库改动占比
"server" : 42
"app" : 35
''';
    final norm = normalizeMermaidForFlutter(raw);
    expect(parser.parseWithData(norm), isNotNull);
  });

  test('radar shorthand to radar-beta', () {
    const raw = '''
radar
title 对比
"语法完整度" : 3
"性能" : 8
''';
    final norm = normalizeMermaidForFlutter(raw);
    expect(norm, contains('radar-beta'));
    expect(parser.parseWithData(norm), isNotNull);
  });

  test('kanban section syntax', () {
    const raw = '''
kanban
title 功能看板
section 待办
  Mermaid 样例库
section 完成
  gpt_markdown
''';
    final norm = normalizeMermaidForFlutter(raw);
    expect(norm, contains('col1[待办]'));
    expect(parser.parseWithData(norm), isNotNull);
  });

  test('flowchart subgraph with CJK label', () {
    const raw = '''
graph LR
  subgraph 客户端
    A[打开] --> B[结束]
  end
''';
    final norm = normalizeMermaidForFlutter(raw);
    expect(norm, contains('subgraph sg1[客户端]'));
    expect(parser.parseWithData(norm), isNotNull);
  });

  test('gantt example from chat samples', () {
    const raw = '''
gantt
  title 问象迭代
  dateFormat YYYY-MM-DD
  section Markdown
  flutter_markdown 迁移     :done,    md1, 2026-03-01, 3d
  gpt_markdown 统一         :done,    md2, after md1, 2d
  flutter_mermaid           :active,  md3, after md2, 2d
''';
    expect(parser.parseWithData(normalizeMermaidForFlutter(raw)), isNotNull);
  });

  test('sequence drops Note lines', () {
    const raw = '''
sequenceDiagram
  participant A as Alice
  participant B as Bob
  A->>B: hello
  Note over A,B: ignored
  B-->>A: hi
''';
    final norm = normalizeMermaidForFlutter(raw);
    expect(norm, isNot(contains('Note over')));
    expect(parser.parseWithData(norm), isNotNull);
  });
}
