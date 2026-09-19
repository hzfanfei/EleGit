import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/voice/book_quick_voice_session.dart';

void main() {
  test('statusLabel covers voice pipeline phases', () {
    final session = BookQuickVoiceSession(
      api: WenxiangApi(baseUrl: 'http://127.0.0.1:8787', apiKey: 'test'),
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
}
