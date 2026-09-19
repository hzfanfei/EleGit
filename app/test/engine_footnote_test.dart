import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/engine.dart';

void main() {
  test('footnotes stay user-facing, not technical engine ids', () {
    expect(engineFootnote('local-progress'), '基于本地进度');
    expect(engineFootnote('acp'), '');
    expect(engineFootnote('cursor-agent'), '');
    expect(engineFootnote(''), '');
    expect(engineFootnote(null), '');
  });
}
