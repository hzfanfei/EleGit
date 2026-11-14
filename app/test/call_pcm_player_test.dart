import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/call_pcm_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(CallPcmPlayer.channel, null));

  test('uses one track for consecutive chunks and waits for actual playback', () async {
    final calls = <String>[];
    var accepted = 0;
    var head = 0;
    var captions = 0;
    messenger.setMockMethodCallHandler(CallPcmPlayer.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'push') { final start = accepted; accepted += 100; return start; }
      if (call.method == 'status') return {'head': head, 'remaining': accepted - head};
      return null;
    });
    final player = CallPcmPlayer();
    await player.push(Uint8List(200), 24000, () => captions++);
    await player.push(Uint8List(200), 24000, () => captions++);
    var drained = false;
    final drain = player.waitForIdle().then((_) => drained = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(drained, false);
    expect(captions, 1);
    head = 200;
    await drain;
    expect(captions, 2);
    expect(calls.where((s) => s == 'open').length, 1);
    await player.stop();
  });

  test('stop discards a chunk still waiting for the native open response', () async {
    final opening = Completer<void>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(CallPcmPlayer.channel, (call) async {
      calls.add(call.method);
      if (call.method == 'open') await opening.future;
      return null;
    });
    final player = CallPcmPlayer();
    final push = player.push(Uint8List(200), 24000, null);
    await Future<void>.delayed(Duration.zero);
    await player.stop();
    opening.complete();
    await push;
    expect(calls, ['open', 'stop']);
  });

  test('native open and stop timeouts are bounded', () async {
    messenger.setMockMethodCallHandler(CallPcmPlayer.channel, (_) => Completer<Object?>().future);
    final player = CallPcmPlayer(commandTimeout: const Duration(milliseconds: 30));
    await expectLater(player.push(Uint8List(200), 24000, null), throwsA(isA<TimeoutException>()));
    await expectLater(player.stop(), throwsA(isA<TimeoutException>()));
  });

  test('a stuck native playback head reports failure instead of waiting forever', () async {
    messenger.setMockMethodCallHandler(CallPcmPlayer.channel, (call) async {
      if (call.method == 'push') return 0;
      if (call.method == 'status') return {'head': 0, 'remaining': 100};
      return null;
    });
    final player = CallPcmPlayer(stallTimeout: const Duration(milliseconds: 40));
    await player.push(Uint8List(200), 24000, null);
    await expectLater(player.waitForIdle(), throwsA(isA<TimeoutException>()));
    await player.stop();
  });
}
