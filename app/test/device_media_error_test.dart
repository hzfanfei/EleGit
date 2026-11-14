import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/device_media.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('xyz.luan/audioplayers');
  const codec = StandardMethodCodec();
  final calls = <String>[];
  var sourceAttempts = 0;
  var failures = 0;
  var failAfterStart = false;

  void emit(String id,
      {bool error = false, String event = 'audio.onPrepared'}) {
    messenger.handlePlatformMessage(
        'xyz.luan/audioplayers/events/$id',
        error
            ? codec.encodeErrorEnvelope(
                code: 'AndroidAudioError', message: 'Failed to set source')
            : codec.encodeSuccessEnvelope({'event': event, 'value': true}),
        (_) {});
  }

  setUp(() {
    calls.clear();
    sourceAttempts = 0;
    failures = 0;
    failAfterStart = false;
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'com.llfbandit.record/messages'
    ]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      final id = call.arguments['playerId'] as String;
      if (call.method == 'create') {
        messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null);
      }
      if (call.method == 'setSourceBytes') {
        sourceAttempts++;
        emit(id, error: sourceAttempts <= failures);
      }
      if (call.method == 'resume') {
        Timer(const Duration(milliseconds: 10),
            () => emit(id, error: failAfterStart, event: 'audio.onComplete'));
      }
      return null;
    });
  });

  test('native source event error is caught and releases decoder before retry',
      () async {
    failures = 1;
    final media = DeviceVoiceMedia();
    var starts = 0;
    await media.playPcm(Uint8List(200), onPlaybackStart: () => starts++);
    await media.waitForPlaybackQueue();
    expect(sourceAttempts, 2);
    expect(calls, contains('release'));
    expect(starts, 1);
    media.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  test('three rejected sources fail queue and a later request can recover',
      () async {
    failures = 3;
    final media = DeviceVoiceMedia();
    await expectLater(
        media.playPcm(Uint8List(200)), throwsA(isA<PlatformException>()));
    expect(sourceAttempts, 3);
    await expectLater(
        media.waitForPlaybackQueue(), throwsA(isA<PlatformException>()));
    failures = 0;
    await media.playPcm(Uint8List(200));
    await media.waitForPlaybackQueue();
    media.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  test(
      'error after playback starts fails promptly without unhandled stream error',
      () async {
    failAfterStart = true;
    final media = DeviceVoiceMedia();
    await expectLater(
        media.playPcm(Uint8List(200)).timeout(const Duration(seconds: 1)),
        throwsA(isA<PlatformException>()));
    media.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
}
