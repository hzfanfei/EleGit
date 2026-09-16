import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/copy/time.dart';

void main() {
  final now = DateTime.utc(2026, 9, 16, 5);

  test('relative time uses yesterday and day counts', () {
    expect(
      formatRelativeTime('2026-09-16T04:30:00Z', now: now),
      contains('分钟前'),
    );
    expect(formatRelativeTime('2026-09-15T00:00:00Z', now: now), '昨天');
    expect(formatRelativeTime('2026-09-01T00:00:00Z', now: now), '15 天前');
  });

  test('empty or invalid timestamps stay blank', () {
    expect(formatRelativeTime(''), isEmpty);
    expect(formatRelativeTime('not-a-date'), isEmpty);
  });
}
