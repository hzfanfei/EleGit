import '../diagnostics/client_error_log.dart';

/// User-facing wording for [error], without writing to the log.
String explainError(Object error) => _explain(error);

/// Persist [error] for the in-app log center (deduped inside [ClientErrorLog]).
void recordClientError(
  Object error, {
  String kind = 'error',
  String? summary,
  String? stack,
}) {
  final raw = error.toString().trim();
  if (raw.isEmpty || raw == 'cancelled') return;
  ClientErrorLog.instance.note(
    message: raw,
    summary: summary ?? explainError(error),
    stack: stack ?? '',
    kind: kind,
  );
}

/// Short UI hint plus optional underlying cause (voice / websocket / server detail).
void recordClientFault(
  String summary, {
  Object? cause,
  String kind = 'voice',
}) {
  final hint = summary.trim();
  if (hint.isEmpty) return;
  final detail = cause?.toString().trim() ?? '';
  if (detail.isEmpty || detail == hint) {
    recordClientError(hint, kind: kind, summary: hint);
    return;
  }
  ClientErrorLog.instance.note(
    message: detail,
    summary: hint,
    kind: kind,
  );
}

/// Milestone for voice/TTS diagnosis (log center, kind=voice).
void recordVoiceTrace(String summary, {String? detail}) {
  final hint = summary.trim();
  if (hint.isEmpty) return;
  final body = detail?.trim() ?? '';
  ClientErrorLog.instance.note(
    message: body.isEmpty ? hint : body,
    summary: hint,
    kind: 'voice',
  );
}

String voiceLogClip(String text, [int max = 56]) {
  final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (cleaned.isEmpty) return '—';
  if (cleaned.length <= max) return cleaned;
  return '${cleaned.substring(0, max)}…';
}

String humanizeError(Object error) {
  final text = explainError(error);
  recordClientError(error, summary: text, kind: 'shown');
  return text;
}

String _explain(Object error) {
  final raw = error.toString().trim();
  if (raw.isEmpty) return '出了点问题。请稍后重试。';

  final compact = raw.replaceAll(RegExp(r'\s+'), ' ');
  final lower = compact.toLowerCase();

  if (_readableChinese(compact)) return compact;
  if (_isLeftoverDest(lower)) return '本机目录不完整。请重试。';
  if (_isRepoMissing(lower)) return '找不到这个仓库。';

  if (_isSseDrop(lower)) {
    return '连接中断了。请重试。';
  }
  if (_isHandshake(lower)) {
    return '公网隧道握手失败。请确认电脑上的问象服务和 ngrok 都在运行后重试。';
  }
  if (_isNetwork(lower)) {
    return '连不上本机问象服务。请确认电脑上的服务已启动。';
  }
  if (_isAuth(lower)) {
    return 'GitHub 尚未授权，或登录已失效。请重新打开 GitHub 完成授权。';
  }
  if (_isGitMissing(lower)) {
    return '本机未找到 Git。请安装 Git for Windows，然后重启问象服务。';
  }
  if (_isClone(lower)) {
    return '仓库克隆失败。请稍后重试，或换一个仓库。';
  }
  if (lower.contains('engine') && (lower.contains('unavail') || lower.contains('fail'))) {
    return '暂时无法回答。请稍后重试。';
  }
  if (lower.contains('session not found')) {
    return '问书会话已过期。请再问一次。';
  }

  return '出了点问题。请稍后重试。';
}

String? errorDetail(Object error) {
  final raw = redactSecrets(error.toString().trim());
  if (raw.isEmpty) return null;
  final human = humanizeError(error);
  if (raw == human || _readableChinese(raw)) return null;
  return raw.length > 800 ? '${raw.substring(0, 800)}…' : raw;
}

bool _readableChinese(String text) {
  if (text.contains('Exception') || text.contains('Error:')) return false;
  final chinese = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
  if (chinese == 0) return false;
  final letters = RegExp(r'[A-Za-z]').allMatches(text).length;
  return chinese >= letters && text.length <= 240;
}

bool _isLeftoverDest(String lower) {
  return lower.contains('already exists') && lower.contains('not an empty directory');
}

bool _isRepoMissing(String lower) {
  return lower.contains('repository not found') ||
      (lower.contains('not found') && lower.contains('github.com'));
}

bool _isHandshake(String lower) {
  return lower.contains('handshake') || lower.contains('certificate');
}

bool _isNetwork(String lower) {
  return lower.contains('socketexception') ||
      lower.contains('connection refused') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection reset') ||
      lower.contains('network is unreachable') ||
      lower.contains('timed out') ||
      lower.contains('timeout') ||
      lower.contains('failed to fetch') ||
      lower.contains('clientexception') ||
      lower.contains('xmlhttprequest');
}

bool _isAuth(String lower) {
  return lower.contains('unauthorized') ||
      lower.contains('forbidden') ||
      lower.contains('401') ||
      lower.contains('403');
}

bool _isGitMissing(String lower) {
  return lower.contains('spawn git enoent') ||
      lower.contains('git_not_found') ||
      (lower.contains('enoent') && lower.contains('git'));
}

bool _isClone(String lower) {
  return lower.contains('clone') ||
      lower.contains('checkout') ||
      lower.contains('authentication failed');
}

bool isChatTransportDrop(Object error) {
  return _isSseDrop(error.toString().toLowerCase());
}

/// Server-side ACP session already gone (e.g. companion restarted).
bool isStaleSessionError(Object error) {
  final lower = error.toString().toLowerCase();
  return lower.contains('session not found');
}

bool _isSseDrop(String lower) {
  return lower.contains('connection closed') ||
      lower.contains('connection abort') ||
      lower.contains('broken pipe') ||
      lower.contains('stream ended') ||
      (lower.contains('sse') && (lower.contains('drop') || lower.contains('interrupt')));
}
