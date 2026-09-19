String engineFootnote(String? engine) {
  if (engine == null || engine.isEmpty) return '';
  if (engine == 'local-progress') return '基于本地进度';
  return '';
}
