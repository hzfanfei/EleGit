import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/diagnostics/client_error_log.dart';
import 'package:wenxiang/screens/log_center_page.dart';
import 'package:wenxiang/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('log center lists entries and copies all', (tester) async {
    final dir = Directory.systemTemp.createTempSync('wx-log-center-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final previous = ClientErrorLog.instance;
    final log = ClientErrorLog(root: dir);
    ClientErrorLog.instance = log;
    addTearDown(() => ClientErrorLog.instance = previous);

    log.note(message: 'SocketException: timed out', summary: '连不上本机问象服务', kind: 'shown');
    await log.idle;

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const LogCenterPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('日志中心'), findsOneWidget);
    expect(find.textContaining('连不上本机问象服务'), findsOneWidget);

    await tester.tap(find.byKey(const Key('log-center-copy-all')));
    await tester.pumpAndSettle();
    expect(find.text('已复制 1 条日志'), findsOneWidget);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    expect(data?.text, contains('timed out'));

    await tester.tap(find.textContaining('连不上本机问象服务'));
    await tester.pumpAndSettle();
    expect(find.text('日志详情'), findsOneWidget);
    expect(find.byKey(const Key('log-entry-detail-body')), findsOneWidget);
    expect(find.textContaining('timed out'), findsWidgets);
  });
}
