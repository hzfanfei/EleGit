import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/errors.dart';
import 'package:wenxiang/diagnostics/client_error_log.dart';
import 'package:wenxiang/screens/log_center_page.dart';
import 'package:wenxiang/theme.dart';

void main() {
  testWidgets('log center lists recorded client errors', (tester) async {
    final dir = Directory.systemTemp.createTempSync('wx-log-center-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final previous = ClientErrorLog.instance;
    ClientErrorLog.instance = ClientErrorLog(root: dir);
    addTearDown(() => ClientErrorLog.instance = previous);

    recordClientError('SocketException: Connection refused', kind: 'chat');
    await ClientErrorLog.instance.idle;

    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: const LogCenterPage(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('日志中心'), findsOneWidget);
    expect(find.textContaining('连不上本机问象服务'), findsOneWidget);
  });
}
