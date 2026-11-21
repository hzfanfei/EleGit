import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/utils/wx_mermaid_cache.dart';
import 'package:wenxiang/widgets/wx_mermaid_svg_block.dart';
import 'package:wenxiang/widgets/wx_rich_text.dart';

const _svg = '''
<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40" viewBox="0 0 80 40">
  <rect width="80" height="40" fill="#ccc"/>
</svg>
''';

class _DiagramApi extends WenxiangApi {
  _DiagramApi() : super(baseUrl: 'http://localhost', apiKey: 'test');

  final requests = <String, Completer<MermaidRender>>{};

  @override
  Future<MermaidRender> renderMermaidSvg(
    String code, {
    String theme = 'default',
    String backgroundColor = 'transparent',
  }) {
    final pending = Completer<MermaidRender>();
    requests[code] = pending;
    return pending.future;
  }
}

Future<void> _showDiagram(
  WidgetTester tester,
  WenxiangApi api,
  String code,
) =>
    tester.pumpWidget(MaterialApp(
      theme: wenxiangTheme(),
      home: Scaffold(
        body: WxMermaidSvgBlock(
          code: code,
          closed: true,
          api: api,
          serverTheme: 'default',
        ),
      ),
    ));

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
  test('failed Mermaid requests are shared and can be retried', () async {
    final cache = WxMermaidCache.instance;
    cache.clear();
    addTearDown(cache.clear);
    final request = Completer<MermaidRender>();
    final error = StateError('render failed');
    final first = cache.load('test', () => request.future);
    final second =
        cache.load('test', () => throw StateError('duplicate fetch'));
    expect(identical(first, second), isTrue);
    final handled = expectLater(first, throwsA(same(error)));
    request.completeError(error);
    await handled;
    await expectLater(
        cache.load('test', () => throw error), throwsA(same(error)));
    const diagram = MermaidRender(svg: _svg);
    expect(await cache.load('test', () async => diagram), same(diagram));
    expect(cache.peek('test'), same(diagram));
  });

  testWidgets('late Mermaid response cannot replace a cached diagram',
      (tester) async {
    final cache = WxMermaidCache.instance;
    cache.clear();
    addTearDown(cache.clear);
    final api = _DiagramApi();
    const previous = 'graph TD\nA --> B';
    const current = 'graph TD\nC --> D';
    final key = WxMermaidCache.key(
        code: current, theme: 'default', backgroundColor: 'transparent');
    cache.remember(key, const MermaidRender(svg: _svg));
    await _showDiagram(tester, api, previous);
    await _showDiagram(tester, api, current);
    final picture = find.byType(SvgPicture);
    final height = tester.widget<SvgPicture>(picture).height;
    expect(api.requests.keys, [previous]);
    api.requests[previous]!.complete(const MermaidRender(
      svg: '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 80 320"/>',
    ));
    await tester.pump();
    expect(tester.widget<SvgPicture>(picture).height, height);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed Mermaid render shows copyable source', (tester) async {
    final cache = WxMermaidCache.instance;
    cache.clear();
    addTearDown(cache.clear);
    final api = _DiagramApi();
    const code = 'graph TD\nA --> B';
    await _showDiagram(tester, api, code);
    api.requests[code]!.completeError(ApiException('无法绘制图表'));
    await tester.pumpAndSettle();
    expect(find.text('无法绘制图表'), findsOneWidget);
    expect(tester.widget<WxFencedCode>(find.byType(WxFencedCode)).code, code);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击图表预览会退出', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('wx-diagram-stage')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('wx-diagram-stage')), findsNothing);
    expect(find.text('打开'), findsOneWidget);
  });

  testWidgets('拖动预览不会退出', (tester) async {
    await _open(tester);
    await tester.drag(
        find.byKey(const Key('wx-diagram-stage')), const Offset(80, 0));
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
