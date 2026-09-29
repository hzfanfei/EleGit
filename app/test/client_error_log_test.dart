import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/copy/errors.dart';
import 'package:wenxiang/diagnostics/client_error_log.dart';
import 'package:wenxiang/persist/app_memory.dart';
import 'package:wenxiang/screens/shell_page.dart';
import 'package:wenxiang/theme.dart';

import 'support/fake_api.dart';

void main() {
  test('keeps the reason locally until those ids are uploaded', () async {
    final dir = Directory.systemTemp.createTempSync('wx-client-log-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final log = ClientErrorLog(root: dir, maxEntries: 3);
    log.note(
      message: 'SocketException: Connection refused',
      summary: '连不上本机问象服务',
      kind: 'shown',
    );
    log.note(message: 'cancelled', kind: 'shown');
    log.note(
      message: 'SocketException: Connection refused',
      summary: '连不上本机问象服务',
      kind: 'shown',
    );
    await log.idle;
    final pending = await log.peek(10);
    expect(pending, hasLength(1));
    expect(pending.single['message'], 'SocketException: Connection refused');
    expect(pending.single['summary'], '连不上本机问象服务');

    final reloaded = ClientErrorLog(root: dir, maxEntries: 3);
    final stored = await reloaded.peek(10);
    expect(stored, hasLength(1));
    await log.drop([pending.single['id'] as String]);
    expect(await log.peek(10), isEmpty);
    final afterUpload = ClientErrorLog(root: dir, maxEntries: 3);
    expect(await afterUpload.peek(10), isEmpty);
  });

  test('drops the oldest reasons once the local cap is full', () async {
    final dir = Directory.systemTemp.createTempSync('wx-client-log-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final log = ClientErrorLog(root: dir, maxEntries: 2);
    log.note(message: 'one');
    log.note(message: 'two');
    log.note(message: 'three');
    await log.idle;
    final pending = await log.peek(10);
    expect(pending.map((entry) => entry['message']), ['two', 'three']);
  });

  test('a shown error records the raw reason and the Chinese summary', () async {
    final dir = Directory.systemTemp.createTempSync('wx-client-log-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final previous = ClientErrorLog.instance;
    ClientErrorLog.instance = ClientErrorLog(root: dir);
    addTearDown(() => ClientErrorLog.instance = previous);
    const raw = 'SocketException: Connection refused (OS Error: Connection refused, errno = 111)';
    expect(humanizeError(raw), contains('连不上本机问象服务'));
    await ClientErrorLog.instance.idle;
    final pending = await ClientErrorLog.instance.peek(10);
    expect(pending.single['message'], raw);
    expect(pending.single['summary'], contains('连不上本机问象服务'));
    expect(pending.single['kind'], 'shown');
  });

  testWidgets('uploads local errors on startup and when leaving the foreground', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final previous = ClientErrorLog.instance;
    final log = ClientErrorLog(persist: false);
    ClientErrorLog.instance = log;
    addTearDown(() => ClientErrorLog.instance = previous);

    log.note(message: 'SocketException: Connection refused', summary: '连不上本机问象服务');
    await log.idle;

    final api = FakeWenxiangApi();
    final memory = AppMemory(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: ShellPage(api: api, memory: memory),
      ),
    );
    await _flushUploads(tester, log, api, 1);
    expect(api.uploadedClientLogs, hasLength(1));
    expect(api.uploadedClientLogs.single.single['message'], contains('Connection refused'));
    expect(await log.peek(10), isEmpty);

    log.note(message: 'inactive overlay should stay on the phone');
    await log.idle;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(api.uploadedClientLogs, hasLength(1));
    expect(await log.peek(10), hasLength(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await _flushUploads(tester, log, api, 2);
    expect(api.uploadedClientLogs, hasLength(2));
    expect(api.uploadedClientLogs.last.single['message'], 'inactive overlay should stay on the phone');
    expect(await log.peek(10), isEmpty);
  });
}

Future<void> _flushUploads(
  WidgetTester tester,
  ClientErrorLog log,
  FakeWenxiangApi api,
  int uploads,
) async {
  for (var i = 0; i < 20; i += 1) {
    await tester.pump(const Duration(milliseconds: 50));
    final pending = await log.peek(10);
    if (api.uploadedClientLogs.length >= uploads && pending.isEmpty) return;
  }
}
