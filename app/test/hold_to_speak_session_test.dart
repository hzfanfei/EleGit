import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/voice_client.dart';
import 'package:wenxiang/voice/hold_to_speak_session.dart';
import 'package:wenxiang/voice/voice_media.dart';
import 'package:wenxiang/voice/voice_stt_client.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('disconnect during recorder shutdown cannot resurrect busy state', () async {
    final stt = _DisconnectingStt();
    final media = _SlowStopMedia();
    final errors = <String>[];
    final hold = HoldToSpeakSession(
      api: FakeWenxiangApi(),
      sttClient: stt,
      voiceMedia: media,
      onChanged: () {},
      onTranscript: (_) => fail('must not send a transcript'),
      onError: errors.add,
    );
    await hold.beginHold(120);
    final ending = hold.endHold();
    await media.stopping.future;
    stt.events.add(VoiceEvent(type: 'error', code: 'network'));
    await Future<void>.delayed(Duration.zero);
    media.stopped.complete();
    await ending;
    expect(hold.active, isFalse);
    expect(stt.stopCalls, 0);
    expect(errors, hasLength(1));
    hold.dispose();
  });

  test('forwards full multi-sentence STT transcript on done', () async {
    final stt = FakeVoiceSttClient(doneText: '第一句话。第二句话还在说。');
    final media = FakeVoiceMedia();
    String? transcript;
    final hold = HoldToSpeakSession(
      api: FakeWenxiangApi(),
      sttClient: stt,
      voiceMedia: media,
      onChanged: () {},
      onTranscript: (text) => transcript = text,
      onError: (_) {},
    );

    await hold.beginHold(120);
    await hold.endHold();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(transcript, '第一句话。第二句话还在说。');
    hold.dispose();
  });
}

class _DisconnectingStt extends FakeVoiceSttClient {
  final events = StreamController<VoiceEvent>.broadcast();

  @override
  Stream<VoiceEvent> connect() => events.stream;

  @override
  void dispose() {
    if (!events.isClosed) unawaited(events.close());
    super.dispose();
  }
}

class _SlowStopMedia extends FakeVoiceMedia {
  final stopping = Completer<void>();
  final stopped = Completer<void>();

  @override
  Future<void> stopMic() {
    if (!stopping.isCompleted) stopping.complete();
    return stopped.future;
  }
}
