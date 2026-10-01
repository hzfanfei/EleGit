import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_mermaid_svg_block.dart';

const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40" viewBox="0 0 80 40">
  <rect width="80" height="40" fill="#ccc"/>
</svg>
''';

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: wenxiangTheme(),
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    fullscreenDialog: true,
                    builder: (_) => wxDiagramStageForTest(svg: _svg),
                  ),
                );
              },
              child: const Text('打开'),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('wx-diagram-stage')), findsOneWidget);
}

void main() {
  testWidgets('点击图表预览会退出', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('wx-diagram-stage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wx-diagram-stage')), findsNothing);
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('拖动预览不会退出', (tester) async {
    await _open(tester);
    await tester.drag(find.byKey(const Key('wx-diagram-stage')), const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wx-diagram-stage')), findsOneWidget);
  });

  testWidgets('点放大不会退出', (tester) async {
    await _open(tester);
    await tester.tap(find.byTooltip('放大'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wx-diagram-stage')), findsOneWidget);
  });
}
