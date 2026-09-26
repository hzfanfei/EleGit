import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_clone_scrim.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('sync mode shows 正在更新 copy', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: WxCloneScrim(
            repo: sampleRepo(),
            path: '/home/fei/问象/octo/demo',
            mode: WxCloneMode.sync,
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 900));
    expect(find.textContaining('正在更新'), findsWidgets);
    expect(find.textContaining('正在克隆'), findsNothing);
  });

  testWidgets('clone failure shows the real error, not a false not-on-disk title', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: WxCloneScrim(
            repo: sampleRepo(),
            path: '/home/fei/问象/octo/demo',
            error: ApiException(
              "fatal: destination path '/home/fei/问象/octo/demo' already exists and is not an empty directory",
            ),
            onRetry: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );

    expect(find.text('没有落到本机'), findsNothing);
    expect(find.textContaining('还没有写到本机'), findsNothing);
    expect(find.textContaining('already exists'), findsNothing);
    expect(find.textContaining('克隆'), findsWidgets);
    expect(find.textContaining('octo/demo'), findsWidgets);
    expect(find.textContaining('/home/fei/问象/octo/demo'), findsWidgets);
  });
}
