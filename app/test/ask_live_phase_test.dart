import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/ask_live_phase.dart';

void main() {
  test('book wait labels move through concrete steps', () {
    expect(askLivePhaseLabel('connect', book: true), '正在连接问书…');
    expect(askLivePhaseLabel('book', book: true), '对照当前章节…');
    expect(askLivePhaseLabel('generate', book: true), '正在组织回答…');
    expect(askLivePhaseLabel('wait', book: true), '还在翻看，请再等一会儿…');
  });

  test('book fallback advances while the first token is late', () {
    expect(
      nextAskLiveFallbackPhase(
        current: 'connect',
        elapsed: const Duration(milliseconds: 400),
        book: true,
      ),
      isNull,
    );
    expect(
      nextAskLiveFallbackPhase(
        current: 'connect',
        elapsed: const Duration(milliseconds: 1200),
        book: true,
      ),
      'book',
    );
    expect(
      nextAskLiveFallbackPhase(
        current: 'book',
        elapsed: const Duration(seconds: 3),
        book: true,
      ),
      'generate',
    );
    expect(
      nextAskLiveFallbackPhase(
        current: 'generate',
        elapsed: const Duration(seconds: 8),
        book: true,
      ),
      'wait',
    );
  });

  test('repo chat labels stay the same', () {
    expect(askLivePhaseLabel('connect'), '连接 Agent…');
    expect(askLivePhaseLabel('repo'), '读仓库、整理上下文…');
    expect(askLivePhaseLabel('generate'), '生成回答…');
  });
}
