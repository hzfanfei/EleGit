import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/wx_edge_back.dart';

void main() {
  testWidgets('left-edge swipe right and right-edge swipe left call onBack', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WxEdgeBack(
          onBack: () => backs += 1,
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );
    final width = tester.getSize(find.byType(WxEdgeBack)).width;

    final left = await tester.startGesture(const Offset(8, 200));
    await left.moveBy(const Offset(80, 0));
    await left.up();
    await tester.pump();
    expect(backs, 1);

    final right = await tester.startGesture(Offset(width - 8, 200));
    await right.moveBy(const Offset(-80, 0));
    await right.up();
    await tester.pump();
    expect(backs, 2);
  });

  testWidgets('middle swipe does not go back', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WxEdgeBack(
          onBack: () => backs += 1,
          child: const Scaffold(body: Text('home')),
        ),
      ),
    );

    await tester.dragFrom(const Offset(200, 200), const Offset(280, 200));
    await tester.pump();
    expect(backs, 0);
    expect(find.text('home'), findsOneWidget);
  });
}
