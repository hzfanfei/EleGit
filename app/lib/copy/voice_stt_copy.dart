/// User-facing copy for hold-to-speak / STT (Chinese).
String humanizeSttEvent({String? code, String? hint}) {
  if (hint != null && hint.trim().isNotEmpty && _readableChinese(hint.trim())) {
    return hint.trim();
  }
  switch (code) {
    case 'unconfigured':
      return '还没配语音密钥。请在本机问象服务的 .env 里配置。';
    case 'network':
      return '连不上语音识别。请检查网络后重试。';
    case 'asr_auth':
      return '语音密钥无效或已过期。请检查本机 .env 里的语音配置。';
    case 'asr_resource':
      return '语音识别资源未开通或资源 ID 不对。请看配置说明里的火山 ASR 步骤。';
    case 'asr_failed':
      return '语音识别暂时不可用。请稍后重试。';
    case 'empty':
      return '没听清，请按住再说一次。';
    case 'empty_answer':
      return '没有可朗读的内容，请换个问法再试。';
    case 'tts_failed':
    case 'turn_failed':
      return hint != null && _readableChinese(hint.trim())
          ? hint.trim()
          : '快问快答失败，请稍后重试。';
    default:
      return '识别失败。请稍后重试。';
  }
}

String humanizeSttConnectionError(Object error) {
  final raw = error.toString().trim().toLowerCase();
  if (raw.contains('401') || raw.contains('403') || raw.contains('unauthorized')) {
    return '问象授权不对，无法连接语音。请确认 App 里的服务地址和密钥。';
  }
  if (raw.contains('socket') ||
      raw.contains('connection') ||
      raw.contains('timeout') ||
      raw.contains('failed host')) {
    return '连不上问象语音服务。请确认电脑上的问象服务已启动。';
  }
  return humanizeSttEvent(code: 'asr_failed');
}

bool _readableChinese(String text) {
  if (text.contains('Exception') || text.contains('Error:')) return false;
  final chinese = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
  return chinese > 0 && text.length <= 240;
}
