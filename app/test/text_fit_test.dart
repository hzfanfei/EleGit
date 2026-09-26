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
}
