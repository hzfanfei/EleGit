import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/text_fit.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

void main() {
  test('prepareChatMarkdownForDisplay skips table and fence lines', () {
    const table = '| a | b |\n| --- | --- |\n';
    const fence = '```dart\nlongline\n```\n';
    final prose = 'https://example.com/${'x' * 40}\n';
    final src = '$prose$table$fence';
    final out = prepareChatMarkdownForDisplay(src, isTableLine: isMarkdownTableLine);
    expect(out, contains('\u200b'));
    expect(out, contains('| --- | --- |'));
    expect(out.split('\u200b').length, greaterThan(1));
    final fencePart = out.substring(out.indexOf('```'));
    expect(fencePart, contains('longline'));
    expect(fencePart, isNot(contains('\u200b')));
  });

  test('prepareChatMarkdownForDisplay does not break image or link targets', () {
    const image = '![](media/ffd4083baca310209a8f8680701f1110d7ebc2a8.png)';
    const link = '[官网](https://vuejs.org/guide/introduction.html)';
    final out = prepareChatMarkdownForDisplay('$image\n$link\n${'abcdefghij' * 3}');
    expect(out, contains(image));
    expect(out, contains(link));
    expect(out, contains('\u200b'));
  });
}
