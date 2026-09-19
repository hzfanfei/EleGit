import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/book_chat_store.dart';
import 'package:wenxiang/voice/book_quick_voice_session.dart';
import 'package:wenxiang/voice/voice_media.dart';

import 'support/fake_api.dart';

/// Invokes [onPlaybackStart] immediately (like queued device playback per job).
class SegmentCapturingMedia implements VoiceMedia {
  final List<String> captionsAtPlay = [];

  @override
  Future<bool> requestMic() async => true;

  @override
  Stream<Uint8List> startMic() => const Stream.empty();

  @override
  Future<void> stopMic() async {}

  @override
  Future<void> playPcm(
    Uint8List pcm, {
    int sampleRate = 24000,
    String format = 'pcm',
    String codec = 'raw',
    String segmentCaption = '',
    void Function()? onPlaybackStart,
  }) async {
    onPlaybackStart?.call();
    captionsAtPlay.add(segmentCaption);
  }

  @override
  Future<void> stopPlayback() async {}

  @override
  Future<void> waitForPlaybackQueue() async {}

  @override
  void dispose() {}
}

void main() {
  test('voice caption switches when second TTS segment starts playing', () async {
    final api = FakeWenxiangApi(
      bookVoiceTurnEvents: [
        ChatStreamEvent(type: 'caption', text: '第一段。'),
        ChatStreamEvent(type: 'audio', pcm: Uint8List.fromList([0, 1, 0, 1])),
        ChatStreamEvent(type: 'caption', text: '第二段。'),
        ChatStreamEvent(type: 'audio', pcm: Uint8List.fromList([0, 2, 0, 2])),
        ChatStreamEvent(type: 'done', text: '第一段。第二段。', engine: 'acp'),
      ],
    );
    final media = SegmentCapturingMedia();
    var changes = 0;
    final session = BookQuickVoiceSession(
      api: api,
      bookId: 'b',
      chapterHint: '',
      onChanged: () => changes += 1,
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
      voiceMedia: media,
    );

    await session.runVoiceTurnForTest('问题');

    expect(media.captionsAtPlay, ['第一段。', '第二段。']);
    expect(changes, greaterThan(0));
    session.dispose();
  });
}
