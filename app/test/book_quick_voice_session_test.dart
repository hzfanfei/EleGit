import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'dart:async';

import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/book_chat_store.dart';
import 'package:wenxiang/voice/book_quick_voice_session.dart';
import 'package:wenxiang/voice/repo_quick_voice_session.dart';
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

  test('passes selected TTS voice on book and repo voice turns', () async {
    final api = FakeWenxiangApi();
    final book = BookQuickVoiceSession(
      api: api,
      bookId: 'b',
      chapterHint: '',
      onChanged: () {},
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
      voiceMedia: FakeVoiceMedia(),
      resolveTtsVoice: () => 'zh_male_m191_uranus_bigtts',
    );
    await book.runVoiceTurnForTest('问题');
    expect(api.lastBookTtsVoice, 'zh_male_m191_uranus_bigtts');
    book.dispose();

    final repo = RepoQuickVoiceSession(
      api: api,
      owner: 'o',
      repo: 'r',
      onChanged: () {},
      historyForVoice: () => const [],
      resolveSessionId: () => null,
      voiceMedia: FakeVoiceMedia(),
      resolveTtsVoice: () => 'zh_female_xiaohe_uranus_bigtts',
    );
    await repo.runVoiceTurnForTest('问题');
    expect(api.lastRepoTtsVoice, 'zh_female_xiaohe_uranus_bigtts');
    repo.dispose();
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

  test('tap cancel stops hang playback without waiting for TTS drain', () async {
    final api = _GatedBookVoiceApi();
    final media = HangUntilStopMedia();
    final session = BookQuickVoiceSession(
      api: api,
      bookId: 'b',
      chapterHint: '',
      onChanged: () {},
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
      voiceMedia: media,
    );

    final turn = session.runVoiceTurnForTest('问题');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.phase, BookQuickVoicePhase.speaking);
    expect(session.tapToCancelActive, isTrue);

    await session.cancelActiveFlow().timeout(const Duration(seconds: 1));
    await turn.timeout(const Duration(seconds: 1));

    expect(api.cancelBookVoiceTurnCalls, 1);
    expect(media.stopCalls, greaterThan(0));
    expect(session.phase, BookQuickVoicePhase.idle);
    expect(session.voiceCaption, isEmpty);
    expect(session.tapToCancelActive, isFalse);
    session.dispose();
  });

  test('dispose mid-TTS does not wait or notify after teardown', () async {
    final api = _GatedBookVoiceApi();
    final media = HangUntilStopMedia();
    var notifies = 0;
    final session = BookQuickVoiceSession(
      api: api,
      bookId: 'b',
      chapterHint: '',
      onChanged: () => notifies += 1,
      readingPlace: () => const BookReadingPlace(chapter: '第一章'),
      historyForVoice: (_) => const [],
      voiceMedia: media,
    );

    final turn = session.runVoiceTurnForTest('问题');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.phase, BookQuickVoicePhase.speaking);
    final beforeDispose = notifies;

    session.dispose();
    await turn.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(notifies, beforeDispose);
    expect(api.cancelBookVoiceTurnCalls, 1);
  });

  test('repo tap cancel mirrors book idle + stopPlayback', () async {
    final api = _GatedRepoVoiceApi();
    final media = HangUntilStopMedia();
    final session = RepoQuickVoiceSession(
      api: api,
      owner: 'o',
      repo: 'r',
      onChanged: () {},
      historyForVoice: () => const [],
      resolveSessionId: () => null,
      voiceMedia: media,
    );

    final turn = session.runVoiceTurnForTest('问题');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.phase, BookQuickVoicePhase.speaking);

    await session.cancelActiveFlow().timeout(const Duration(seconds: 1));
    await turn.timeout(const Duration(seconds: 1));

    expect(api.cancelRepoVoiceTurnCalls, 1);
    expect(media.stopCalls, greaterThan(0));
    expect(session.phase, BookQuickVoicePhase.idle);
    session.dispose();
  });
}

class _GatedBookVoiceApi extends FakeWenxiangApi {
  final Completer<void> gate = Completer<void>();

  @override
  void cancelBookVoiceTurn() {
    super.cancelBookVoiceTurn();
    if (!gate.isCompleted) {
      gate.completeError(const OperationCancelled());
    }
  }

  @override
  Stream<ChatStreamEvent> bookVoiceTurnStream({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
    String? ttsVoice,
  }) async* {
    lastBookTtsVoice = ttsVoice;
    yield ChatStreamEvent(type: 'caption', text: '第一段。');
    yield ChatStreamEvent(type: 'audio', pcm: Uint8List.fromList([0, 1, 0, 1]));
    await gate.future;
    yield ChatStreamEvent(type: 'done', text: '第一段。', engine: 'acp');
  }
}

class _GatedRepoVoiceApi extends FakeWenxiangApi {
  final Completer<void> gate = Completer<void>();

  @override
  void cancelRepoVoiceTurn() {
    super.cancelRepoVoiceTurn();
    if (!gate.isCompleted) {
      gate.completeError(const OperationCancelled());
    }
  }

  @override
  Stream<ChatStreamEvent> repoVoiceTurnStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? ttsVoice,
    bool agentMode = false,
  }) async* {
    lastRepoTtsVoice = ttsVoice;
    yield ChatStreamEvent(type: 'caption', text: '仓库一句。');
    yield ChatStreamEvent(type: 'audio', pcm: Uint8List.fromList([0, 3, 0, 3]));
    await gate.future;
    yield ChatStreamEvent(type: 'done', text: '仓库一句。', engine: 'acp');
  }
}

class HangUntilStopMedia implements VoiceMedia {
  Completer<void>? _playing;
  int stopCalls = 0;

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
    _playing = Completer<void>();
    await _playing!.future;
  }

  @override
  Future<void> stopPlayback() async {
    stopCalls += 1;
    final play = _playing;
    if (play != null && !play.isCompleted) play.complete();
  }

  @override
  Future<void> waitForPlaybackQueue() async {
    final play = _playing;
    if (play != null) await play.future;
  }

  @override
  void dispose() {
    final play = _playing;
    if (play != null && !play.isCompleted) play.complete();
  }
}
