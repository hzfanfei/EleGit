import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/book_chat_store.dart';
import 'package:wenxiang/voice/book_quick_voice_session.dart';
import 'package:wenxiang/voice/voice_media.dart';

import 'support/fake_api.dart';

void main() {
  test('statusLabel covers voice pipeline phases', () {
    final session = BookQuickVoiceSession(
      api: FakeWenxiangApi(),
      bookId: 'b',
      chapterHint: '',
      onChanged: () {},
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
    );
    session.phase = BookQuickVoicePhase.recognizing;
    expect(session.statusLabel, '识别中…');
    session.phase = BookQuickVoicePhase.thinking;
    expect(session.statusLabel, '思考中…');
    session.phase = BookQuickVoicePhase.speaking;
    expect(session.statusLabel, '播放中…');
    session.dispose();
  });

  test('tapToCancelActive during think/speak pipeline', () {
    final api = FakeWenxiangApi();
    final session = BookQuickVoiceSession(
      api: api,
      bookId: 'b',
      chapterHint: '',
      onChanged: () {},
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
      voiceMedia: FakeVoiceMedia(),
    );
    session.phase = BookQuickVoicePhase.thinking;
    expect(session.tapToCancelActive, isTrue);
    session.phase = BookQuickVoicePhase.idle;
    expect(session.tapToCancelActive, isFalse);
    session.dispose();
  });

  test('cancelActiveFlow clears caption and cancels API', () async {
    final api = FakeWenxiangApi();
    final session = BookQuickVoiceSession(
      api: api,
      bookId: 'b',
      chapterHint: '',
      onChanged: () {},
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
      voiceMedia: FakeVoiceMedia(),
    );
    session.phase = BookQuickVoicePhase.speaking;
    await session.cancelActiveFlow();
    expect(api.cancelBookVoiceTurnCalls, 1);
    expect(session.voiceCaption, isEmpty);
    expect(session.phase, BookQuickVoicePhase.idle);
    session.dispose();
  });

  test('bookVoiceTurnStream reveals caption on audio events', () async {
    final api = FakeWenxiangApi(
      bookVoiceTurnEvents: [
        ChatStreamEvent(type: 'caption', text: 'A'),
        ChatStreamEvent(type: 'audio', pcm: Uint8List.fromList([0, 1, 0, 1])),
        ChatStreamEvent(type: 'caption', text: 'B'),
        ChatStreamEvent(type: 'audio', pcm: Uint8List.fromList([0, 2, 0, 2])),
        ChatStreamEvent(type: 'done', text: 'AB', engine: 'acp'),
      ],
    );
    final events = <ChatStreamEvent>[];
    await for (final e in api.bookVoiceTurnStream(
      bookId: 'b',
      message: 'q',
      history: const [],
    )) {
      events.add(e);
    }
    expect(events.where((e) => e.type == 'caption').length, 2);
    expect(events.where((e) => e.type == 'audio').length, 2);
  });
}
