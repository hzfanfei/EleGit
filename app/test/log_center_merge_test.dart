import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/diagnostics/log_center_merge.dart';

void main() {
  test('merges local and server logs without duplicate ids', () {
    final merged = mergeLogCenterEntries(
      local: [
        {'id': 'a', 'at': '2026-09-25T02:00:00.000Z', 'message': 'local only'},
        {'id': 'b', 'at': '2026-09-25T01:00:00.000Z', 'message': 'both'},
      ],
      remote: [
        {'id': 'b', 'at': '2026-09-25T01:00:00.000Z', 'message': 'server copy', 'origin': 'client'},
        {'id': 'c', 'at': '2026-09-25T03:00:00.000Z', 'message': 'asr fail', 'origin': 'server', 'kind': 'voice-asr'},
      ],
    );
    expect(merged, hasLength(3));
    expect(merged.first['message'], 'asr fail');
    expect(merged.any((e) => e['id'] == 'b' && e['message'] == 'both'), isTrue);
    expect(logScopeLabel({'scope': 'local'}), '本机');
    expect(logScopeLabel({'origin': 'server'}), '问象服务');
  });
}
