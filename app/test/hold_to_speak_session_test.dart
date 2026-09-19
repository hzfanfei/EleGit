import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/hold_to_speak_session.dart';
import 'package:wenxiang/voice/voice_media.dart';
import 'package:wenxiang/voice/voice_stt_client.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
