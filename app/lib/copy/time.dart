String formatRelativeTime(String iso, {DateTime? now}) {
  if (iso.isEmpty) return '';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return '';
  final event = parsed.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final delta = current.difference(event);
  if (delta.isNegative || delta.inSeconds < 90) return '刚刚';
  if (delta.inMinutes < 60) return '${delta.inMinutes} 分钟前';

  final startOfToday = DateTime(current.year, current.month, current.day);
  final startOfEvent = DateTime(event.year, event.month, event.day);
  final days = startOfToday.difference(startOfEvent).inDays;
  if (days <= 0) return '${delta.inHours} 小时前';
  if (days == 1) return '昨天';
  if (days < 30) return '$days 天前';
  return '${event.year}-${_two(event.month)}-${_two(event.day)}';
}

String _two(int n) => n.toString().padLeft(2, '0');
