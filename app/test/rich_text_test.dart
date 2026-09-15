import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

void main() {
  test('splits fenced code from prose', () {
    const src = '说明如下：\n```\nvoid main() {}\n```\n结束';
    final parts = splitRichBlocks(src);
    expect(parts, hasLength(3));
    expect(parts[0].kind, RichKind.prose);
    expect(parts[1].kind, RichKind.code);
    expect(parts[1].text, contains('void main()'));
    expect(parts[2].kind, RichKind.prose);
  });
}
