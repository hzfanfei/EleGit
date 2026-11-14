import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/voice/voice_media.dart';
import 'package:wenxiang/widgets/wx_speak_answer.dart';
import 'support/fake_api.dart';

class _SpeechApi extends FakeWenxiangApi {
  @override
  Stream<ChatStreamEvent> speakSummaryStream(
      {required String text, String? ttsVoice}) async* {
    yield ChatStreamEvent(type: 'audio', pcm: Uint8List(8));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    yield ChatStreamEvent(type: 'audio', pcm: Uint8List(8));
  }
}

class _FailedMedia extends FakeVoiceMedia {
  int plays = 0;
  @override
  Future<void> playPcm(Uint8List pcm,
      {int sampleRate = 24000,
      String format = 'pcm',
      String codec = 'raw',
      String segmentCaption = '',
      void Function()? onPlaybackStart}) async {
    plays++;
    throw PlatformException(
        code: 'AndroidAudioError', message: 'Failed to set source');
  }
}

void main() {
  test('source failure is caught, reported once and stops subsequent audio',
      () async {
    final media = _FailedMedia();
    final speech = AnswerSpeech(media: media);
    final errors = <String>[];
    await speech.toggle(
        id: 'answer', text: 'hello', api: _SpeechApi(), onError: errors.add);
    expect(errors, ['声音播放失败，请重试']);
    expect(media.plays, 1);
    expect(speech.playing, false);
    expect(speech.thinking, false);
    expect(speech.activeId, null);
    speech.dispose();
  });
}
