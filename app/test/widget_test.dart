import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/main.dart';

void main() {
  testWidgets('app opens as 问象 without a settings form', (tester) async {
    await tester.pumpWidget(const WenxiangApp());
    await tester.pump();
    expect(find.textContaining('问象'), findsWidgets);
    expect(find.text('测试连接'), findsNothing);
    expect(find.text('API Key'), findsNothing);
    expect(find.text('服务地址'), findsNothing);
  });
}
