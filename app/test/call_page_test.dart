import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/screens/call_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/voice/voice_client.dart';
import 'package:wenxiang/voice/voice_media.dart';

import 'support/fake_api.dart';

void main() {
  testWidgets('missing keys show a Chinese setup hint and never start a fake call', (tester) async {
    final media = FakeVoiceMedia();
    final client = FakeVoiceClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: CallPage(
          api: FakeWenxiangApi(),
          repo: sampleRepo(),
          onBack: () {},
          media: media,
          client: client,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('还没配语音密钥'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('开始通话'), findsOneWidget);
    expect(find.textContaining('OpenAI'), findsNothing);
    expect(find.textContaining('Volc'), findsNothing);
    expect(find.text('API Key'), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(client.connectCalls, 0);
    expect(media.startCalls, 0);

    await tester.tap(find.text('开始通话'));
    await tester.pump();
    expect(client.connectCalls, 0);
    expect(find.text('在听'), findsNothing);
  });

  testWidgets('ready call walks 连接中 / 在听 / 在说 / 你打断了', (tester) async {
    final media = FakeVoiceMedia();
    final client = FakeVoiceClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: CallPage(
          api: FakeWenxiangApi(voiceReady: true),
          repo: sampleRepo(),
          onBack: () {},
          media: media,
          client: client,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('开始通话'), findsOneWidget);
    await tester.tap(find.text('开始通话'));
    await tester.pump();
    expect(find.text('连接中'), findsOneWidget);
    expect(client.connectCalls, 1);
    expect(media.requestCalls, 1);
    expect(media.startCalls, 1);

    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    expect(find.text('在听'), findsOneWidget);
    expect(find.text('挂断'), findsOneWidget);

    client.emit(VoiceEvent(type: 'state', state: 'speaking'));
    await tester.pump();
    expect(find.text('在说'), findsOneWidget);

    client.emit(VoiceEvent(type: 'state', state: 'barge'));
    await tester.pump();
    expect(find.text('你打断了'), findsOneWidget);
    expect(media.stopPlayCalls, greaterThan(0));
  });

  testWidgets('microphone denial stays on a short Chinese retry', (tester) async {
    final media = FakeVoiceMedia(micGranted: false);
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: CallPage(
          api: FakeWenxiangApi(voiceReady: true),
          repo: sampleRepo(),
          onBack: () {},
          media: media,
          client: FakeVoiceClient(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('开始通话'));
    await tester.pump();
    expect(find.text('需要麦克风才能通话'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('在听'), findsNothing);
  });
}
