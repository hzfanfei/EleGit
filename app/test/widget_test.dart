import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/main.dart';

void main() {
  testWidgets('setup screen shows 问象 title', (tester) async {
    await tester.pumpWidget(const WenxiangApp());
    await tester.pump();
    expect(find.textContaining('问象'), findsWidgets);
    expect(find.text('测试连接'), findsOneWidget);
  });
}
