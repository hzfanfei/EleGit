import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/wx_typewriter_stream.dart';

void main() {
  testWidgets('rejoins a grapheme split across streamed chunks',
      (tester) async {
    final typewriter = WxTypewriterStream();
    addTearDown(typewriter.dispose);

    typewriter.push('前👩');
    await tester.pump(const Duration(milliseconds: 32));
    expect(typewriter.visible.value, '前👩');

    typewriter.push('\u200d💻后');
    await tester.pump(const Duration(milliseconds: 16));
    expect(typewriter.visible.value, '前👩‍💻');
    await tester.pump(const Duration(milliseconds: 16));
    expect(typewriter.visible.value, '前👩‍💻后');
    expect(typewriter.isIdle, isTrue);
  });

  test('reveals characters gradually then finishes', () async {
    final tw = WxTypewriterStream(tick: const Duration(milliseconds: 10));
    addTearDown(tw.dispose);

    tw.push('你好世界');
    expect(tw.visible.value, '');

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(tw.visible.value.length, greaterThan(0));
    expect(tw.visible.value.length, lessThan(tw.fullText.characters.length));

    await tw.animateToEnd(budget: const Duration(milliseconds: 80));
    expect(tw.visible.value, '你好世界');
    expect(tw.isIdle, isTrue);
  });
}
