import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/engine.dart';

void main() {
  test('agent engines never leak vendor or acp names', () {
    expect(engineFootnote('local-progress'), '来自本地进度适配器');
    expect(engineFootnote('acp'), '来自 Agent');
    expect(engineFootnote('cursor-agent'), '来自 Agent');
    expect(engineFootnote(''), '');
    expect(engineFootnote(null), '');
  });
}
