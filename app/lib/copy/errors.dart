String humanizeError(Object error) {
  final raw = error.toString().trim();
  if (raw.isEmpty) return '出了点问题。请稍后重试。';

  final compact = raw.replaceAll(RegExp(r'\s+'), ' ');
  final lower = compact.toLowerCase();

  if (_readableChinese(compact)) return compact;

  if (_isSseDrop(lower)) {
    return '连接中断了。请重试。';
  }
  if (_isNetwork(lower)) {
    return '连不上本机问象服务。请确认电脑上的服务已启动。';
  }
  if (_isAuth(lower)) {
    return 'GitHub 尚未授权，或登录已失效。请重新打开 GitHub 完成授权。';
  }
  if (_isClone(lower)) {
    return '仓库克隆失败。请稍后重试，或换一个仓库。';
  }
  if (lower.contains('engine') && (lower.contains('unavail') || lower.contains('fail'))) {
    return '问答引擎暂时不可用。请稍后重试。';
  }

  return '出了点问题。请稍后重试。';
}

String? errorDetail(Object error) {
  final raw = error.toString().trim();
  if (raw.isEmpty) return null;
  final human = humanizeError(error);
  if (raw == human || _readableChinese(raw)) return null;
  return raw.length > 240 ? '${raw.substring(0, 240)}…' : raw;
}

bool _readableChinese(String text) {
  return RegExp(r'[\u4e00-\u9fff]').hasMatch(text) &&
      !text.contains('Exception') &&
      !text.contains('Error:') &&
      text.length <= 80;
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

bool _isClone(String lower) {
  return lower.contains('clone') ||
      lower.contains('checkout') ||
      lower.contains('authentication failed');
}

bool _isSseDrop(String lower) {
  return lower.contains('connection closed') ||
      lower.contains('connection abort') ||
      lower.contains('broken pipe') ||
      lower.contains('stream ended') ||
      (lower.contains('sse') && (lower.contains('drop') || lower.contains('interrupt')));
}
