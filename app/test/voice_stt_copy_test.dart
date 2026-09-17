import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/voice_stt_copy.dart';

void main() {
  test('humanizeSttEvent prefers server hint when Chinese', () {
    expect(
      humanizeSttEvent(code: 'asr_failed', hint: '语音识别响应超时。请检查网络后重试。'),
      '语音识别响应超时。请检查网络后重试。',
    );
  });

  test('humanizeSttEvent maps codes', () {
    expect(humanizeSttEvent(code: 'unconfigured'), contains('还没配语音密钥'));
    expect(humanizeSttEvent(code: 'asr_resource'), contains('资源'));
    expect(humanizeSttEvent(code: 'empty'), contains('没听清'));
  });

  test('humanizeSttConnectionError maps auth and network', () {
    expect(humanizeSttConnectionError('WebSocketException: HTTP status code: 401'), contains('授权'));
    expect(humanizeSttConnectionError('SocketException: Connection refused'), contains('连不上'));
  });
}
