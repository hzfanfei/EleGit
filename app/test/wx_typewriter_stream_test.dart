import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/wx_typewriter_stream.dart';

void main() {
  test('reveals characters gradually then finishes', () async {
    final tw = WxTypewriterStream(tick: const Duration(milliseconds: 10));
    addTearDown(tw.dispose);

    tw.push('你好世界');
    expect(tw.visible.value, '你好');

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(tw.visible.value.length, greaterThan(0));
    expect(tw.visible.value.length, lessThan(tw.fullText.characters.length));

    await tw.animateToEnd(budget: const Duration(milliseconds: 80));
    expect(tw.visible.value, '你好世界');
    expect(tw.isIdle, isTrue);
  });

  test('first push after reset reveals small chunk immediately', () {
    final tw = WxTypewriterStream();
    addTearDown(tw.dispose);

    tw.push('好');
    expect(tw.visible.value, '好');
  });
}
