import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/widgets/wx_hold_to_speak.dart';

void main() {
  testWidgets('hold pad and live chip expose stable keys', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: Column(
            children: [
              const WxHoldLiveChip(text: '你好世界', recognizing: false),
              WxHoldToSpeakPad(
                enabled: true,
                holding: false,
                holdCancel: false,
                sttBusy: false,
                hint: '按住 说话',
                onHoldStart: (_) async {},
                onHoldMove: (_) {},
                onHoldEnd: () async {},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('wx-hold-speak')), findsOneWidget);
    expect(find.byKey(const Key('wx-hold-live-chip')), findsOneWidget);
    expect(find.text('按住 说话'), findsOneWidget);
    expect(find.text('听到'), findsOneWidget);
  });

  testWidgets('tap pad while recognizing invokes cancel', (tester) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: Scaffold(
          body: WxHoldToSpeakPad(
            enabled: true,
            holding: false,
            holdCancel: false,
            sttBusy: true,
            hint: '识别中，点按取消',
            onHoldStart: (_) async {},
            onHoldMove: (_) {},
            onHoldEnd: () async {},
            onCancelRecognize: () => cancelled = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('wx-hold-speak')));
    expect(cancelled, isTrue);
  });
}
