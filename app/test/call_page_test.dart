import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/screens/call_page.dart';
import 'package:wenxiang/theme.dart';
import 'package:wenxiang/voice/voice_client.dart';
import 'package:wenxiang/voice/voice_media.dart';
import 'package:wenxiang/widgets/wx_chrome.dart';

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

    expect(find.textContaining('还没配语音密钥'), findsOneWidget);
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
    expect(find.textContaining('还没配语音密钥'), findsOneWidget);
  });

  testWidgets('ready call walks 在听 / 思考中 / 在说', (tester) async {
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
    expect(find.text('在听'), findsNothing);
    await tester.tap(find.text('开始通话'));
    await tester.pump();
    expect(find.text('在听'), findsOneWidget);
    expect(find.text('连接中'), findsNothing);
    expect(find.text('你打断了'), findsNothing);
    expect(client.connectCalls, 1);
    expect(media.requestCalls, 1);
    expect(media.startCalls, 1);

    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    expect(find.text('在听'), findsOneWidget);
    expect(find.text('挂断'), findsOneWidget);

    client.emit(VoiceEvent(type: 'caption', role: 'user', text: '最近在做什么', finalCaption: true));
    client.emit(VoiceEvent(type: 'state', state: 'thinking'));
    await tester.pump();
    expect(find.textContaining('最近在做什么'), findsOneWidget);
    expect(find.byType(WxLoading), findsOneWidget);
    expect(find.text('思考中'), findsNothing);
    expect(find.text('在听'), findsNothing);

    client.emit(VoiceEvent(type: 'state', state: 'speaking'));
    await tester.pump();
    expect(find.byType(WxLoading), findsOneWidget);
    expect(find.text('在说'), findsNothing);

    client.emit(VoiceEvent(type: 'pcm', pcm: Uint8List.fromList([1, 0, 2, 0])));
    await tester.pump();
    expect(find.text('在说'), findsOneWidget);
    expect(find.byType(WxLoading), findsNothing);
    expect(find.text('点击打断'), findsNothing);
    expect(find.text('静音'), findsNothing);

    client.emit(VoiceEvent(type: 'state', state: 'barge'));
    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    expect(find.text('在听'), findsOneWidget);
    expect(find.text('你打断了'), findsNothing);
    expect(find.text('在说'), findsNothing);
    expect(media.stopPlayCalls, greaterThan(0));
  });

  testWidgets('tapping the stage does not barge', (tester) async {
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
    expect(find.text('点击打断'), findsNothing);

    await tester.tap(find.text('在说'));
    await tester.pump();
    expect(client.bargeCalls, 0);
    expect(find.text('在说'), findsOneWidget);
    expect(media.stopPlayCalls, 0);

    client.emit(VoiceEvent(type: 'pcm', pcm: Uint8List.fromList([3, 0, 4, 0])));
    await tester.pump();
    expect(media.played, hasLength(2));
  });

  testWidgets('stays 在说 until queued audio finishes', (tester) async {
    final media = _HoldingVoiceMedia();
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
    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    expect(find.text('在说'), findsOneWidget);
    expect(find.text('在听'), findsNothing);

    media.releasePlayback();
    await tester.pump();
    expect(find.text('在听'), findsOneWidget);
    expect(find.text('在说'), findsNothing);
    expect(client.playedCalls, 1);
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
    expect(find.text('详情'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('挂断'), findsNothing);
    expect(find.text('在听'), findsNothing);
    expect(client.hangupCalls, greaterThan(0));
  });

  testWidgets('a dropped call can open and copy the close reason', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    final client = FakeVoiceClient();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: CallPage(
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
    client.emit(VoiceEvent(
      type: 'error',
      code: 'channel',
      hint: '通话断了',
      detail: 'WebSocket closed code=1006',
    ));
    await tester.pump();
    expect(find.text('通话断了'), findsOneWidget);
    expect(find.text('详情'), findsOneWidget);
    expect(find.textContaining('code=1006'), findsNothing);

    await tester.tap(find.text('详情'));
    await tester.pump();
    expect(find.textContaining('code=1006'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(copied, 'WebSocket closed code=1006');
    expect(find.text('已复制'), findsOneWidget);
  });

  testWidgets('a mic that drops mid-call reopens instead of hanging up', (tester) async {
    final media = _DroppingMicMedia();
    final key = GlobalKey<CallPageState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: wenxiangTheme(),
        home: CallPage(
          key: key,
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
    expect(media.startCalls, 1);

    await tester.pump(const Duration(milliseconds: 400));
    expect(media.startCalls, 2);
    expect(key.currentState!.isLive, isTrue);
    expect(find.text('需要麦克风才能通话'), findsNothing);
  });

  testWidgets('talking over the answer keeps the mic open so the rest of the sentence is heard', (tester) async {
    final media = _LiveMicMedia();
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

    client.emit(VoiceEvent(type: 'state', state: 'barge'));
    client.emit(VoiceEvent(type: 'state', state: 'listening'));
    await tester.pump();
    media.speak(9000);
    await tester.pump(const Duration(milliseconds: 500));
    media.speak(9000);
    await tester.pump(const Duration(milliseconds: 800));
    expect(media.stopMicCalls, 0);
    expect(media.startCalls, 1);

    client.emit(VoiceEvent(type: 'state', state: 'speaking'));
    client.emit(VoiceEvent(type: 'pcm', pcm: Uint8List.fromList([1, 0, 2, 0])));
    await tester.pump();
    client.emit(VoiceEvent(type: 'state', state: 'barge'));
    await tester.pump();
    // The voice that triggered the barge got through; the mic went mute right after.
    media.speak(9000);
    await tester.pump(const Duration(milliseconds: 500));
    media.speak(0);
    await tester.pump(const Duration(milliseconds: 800));
    expect(media.stopMicCalls, 1);
    expect(media.startCalls, 2);
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

class _DroppingMicMedia extends FakeVoiceMedia {
  @override
  Stream<Uint8List> startMic() {
    startCalls += 1;
    if (startCalls == 1) {
      return Stream<Uint8List>.value(Uint8List.fromList([1, 0, 0, 0]));
    }
    return StreamController<Uint8List>.broadcast().stream;
  }
}

class _LiveMicMedia extends FakeVoiceMedia {
  final _mic = StreamController<Uint8List>.broadcast();

  void speak(int level) {
    final frame = Uint8List(4);
    ByteData.view(frame.buffer)
      ..setInt16(0, level, Endian.little)
      ..setInt16(2, -level, Endian.little);
    _mic.add(frame);
  }

  @override
  Stream<Uint8List> startMic() {
    startCalls += 1;
    return _mic.stream;
  }
}

class _HoldingVoiceMedia extends FakeVoiceMedia {
  Completer<void>? _gate = Completer<void>();

  void releasePlayback() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<void> waitForPlaybackQueue() {
    final gate = _gate;
    if (gate == null || gate.isCompleted) return Future<void>.value();
    return gate.future;
  }
}
