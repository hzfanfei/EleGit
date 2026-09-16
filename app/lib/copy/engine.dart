String engineFootnote(String? engine) {
  if (engine == null || engine.isEmpty) return '';
  if (engine == 'local-progress') return '来自本地进度适配器';
  return '来自 Agent';
}
