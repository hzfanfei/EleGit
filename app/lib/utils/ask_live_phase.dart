String askLivePhaseLabel(
  String phase, {
  bool book = false,
  String? chapter,
  int secondsElapsed = 0,
}) {
  final trimmed = chapter?.trim() ?? '';
  final showChapter = trimmed.isNotEmpty;
  final waitTail = secondsElapsed > 0 ? '（已等 ${secondsElapsed}s）' : '';

  if (book) {
    switch (phase) {
      case 'book':
        return showChapter ? '对照《$trimmed》…' : '对照当前章节…';
      case 'reading':
        return '正在翻阅上下文…';
      case 'warm':
        return '正在预热会话…';
      case 'generate':
        return '正在组织回答…';
      case 'wait':
        return '还在翻看，请再等一会儿…$waitTail';
      case 'connect':
      default:
        return '正在连接问书…';
    }
  }
  switch (phase) {
    case 'repo':
      return '读仓库、整理上下文…';
    case 'generate':
      return '生成回答…';
    case 'connect':
    default:
      return '正在连接…';
  }
}

/// Next waiting-phase while the first token has not arrived, or null to keep.
String? nextAskLiveFallbackPhase({
  required String current,
  required Duration elapsed,
  bool book = false,
}) {
  if (book) {
    if (elapsed >= const Duration(seconds: 5) && current != 'wait') return 'wait';
    if (elapsed >= const Duration(milliseconds: 1200) && current == 'connect') {
      return 'book';
    }
    return null;
  }
  if (elapsed >= const Duration(seconds: 4) && current != 'generate') {
    return 'generate';
  }
  if (elapsed >= const Duration(milliseconds: 1500) && current == 'connect') {
    return 'repo';
  }
  return null;
}
