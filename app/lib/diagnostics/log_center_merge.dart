List<Map<String, dynamic>> mergeLogCenterEntries({
  required List<Map<String, dynamic>> local,
  required List<Map<String, dynamic>> remote,
  int limit = 200,
}) {
  final cap = limit < 1 ? 1 : limit;
  final byId = <String, Map<String, dynamic>>{};
  for (final row in local) {
    final copy = Map<String, dynamic>.from(row);
    copy['scope'] = 'local';
    final id = copy['id']?.toString() ?? '';
    byId[id.isEmpty ? 'local-${copy.hashCode}' : id] = copy;
  }
  for (final row in remote) {
    final copy = Map<String, dynamic>.from(row);
    final id = copy['id']?.toString() ?? '';
    if (id.isNotEmpty && byId.containsKey(id)) continue;
    byId[id.isEmpty ? 'remote-${copy.hashCode}' : id] = copy;
  }
  final merged = byId.values.toList()
    ..sort((a, b) => (b['at'] ?? '').toString().compareTo((a['at'] ?? '').toString()));
  if (merged.length <= cap) return merged;
  return merged.sublist(0, cap);
}

String logScopeLabel(Map<String, dynamic> entry) {
  if (entry['scope'] == 'local') {
    return entry['synced'] == true ? '本机·已同步' : '本机';
  }
  final origin = entry['origin']?.toString();
  if (origin == 'server') return '问象服务';
  if (origin == 'client') return '问象服务·本机上传';
  return '问象服务';
}
