import 'dart:typed_data';

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

    expect(find.text('还没配语音密钥'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('开始通话'), findsNothing);
    expect(find.text('连接中'), findsNothing);
    expect(find.textContaining('OpenAI'), findsNothing);
    expect(find.textContaining('Volc'), findsNothing);
    expect(find.text('API Key'), findsNothing);
    expect(find.byType(AppBar), findsNothing);
    expect(client.connectCalls, 0);
    expect(media.startCalls, 0);

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(client.connectCalls, 0);
    expect(find.text('在听'), findsNothing);
    expect(find.text('还没配语音密钥'), findsOneWidget);
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
    expect(find.text('连接中'), findsNothing);
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
    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    expect(find.text('你打断了'), findsOneWidget);
    expect(find.text('在听'), findsNothing);
    expect(media.stopPlayCalls, greaterThan(0));

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('在听'), findsOneWidget);
    expect(find.text('你打断了'), findsNothing);
  });

  testWidgets('tapping the stage barges and drops leftover TTS', (tester) async {
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
    await tester.tap(find.text('开始通话'));
    await tester.pump();
    client.emit(VoiceEvent(type: 'state', state: 'speaking'));
    client.emit(VoiceEvent(type: 'pcm', pcm: Uint8List.fromList([1, 0, 2, 0])));
    await tester.pump();
    expect(media.played, hasLength(1));

    await tester.tap(find.byKey(const Key('wx-call-stage')));
    await tester.pump();
    expect(client.bargeCalls, 1);
    expect(find.text('你打断了'), findsOneWidget);

    client.emit(VoiceEvent(type: 'pcm', pcm: Uint8List.fromList([3, 0, 4, 0])));
    await tester.pump();
    expect(media.played, hasLength(1));
  });

  testWidgets('a live channel error hangs up onto a single retry', (tester) async {
    final client = FakeVoiceClient();
    final key = GlobalKey<CallPageState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: CallPage(
          key: key,
          api: FakeWenxiangApi(voiceReady: true),
          repo: sampleRepo(),
          onBack: () {},
          media: FakeVoiceMedia(),
          client: client,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('开始通话'));
    await tester.pump();
    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    expect(key.currentState!.isLive, isTrue);

    client.emit(VoiceEvent(type: 'error', code: 'channel', hint: '通话断了'));
    await tester.pump();
    expect(key.currentState!.isLive, isFalse);
    expect(find.text('通话断了'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('挂断'), findsNothing);
    expect(find.text('在听'), findsNothing);
    expect(client.hangupCalls, greaterThan(0));
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
    expect(find.text('需要麦克风才能通话'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('开始通话'), findsNothing);
    expect(find.text('在听'), findsNothing);
  });
}
