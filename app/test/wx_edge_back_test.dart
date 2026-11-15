import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/widgets/wx_edge_back.dart';

void main() {
  testWidgets('left-edge swipe right and right-edge swipe left call onBack', (tester) async {
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WxEdgeBack(
          enabled: true,
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
          enabled: true,
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

  testWidgets('edge swipes are disabled by default and child taps still work', (tester) async {
    var backs = 0;
    var taps = 0;
    await tester.pumpWidget(MaterialApp(home: WxEdgeBack(
      onBack: () => backs++,
      child: Scaffold(body: TextButton(onPressed: () => taps++, child: const Text('打开'))),
    )));
    await tester.dragFrom(const Offset(8, 200), const Offset(80, 0));
    final width = tester.getSize(find.byType(WxEdgeBack)).width;
    await tester.dragFrom(Offset(width - 8, 200), const Offset(-80, 0));
    await tester.tap(find.text('打开'));
    expect(backs, 0);
    expect(taps, 1);
  });
}
