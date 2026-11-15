import '../chat/running_sessions.dart';

/// A single current status, never the accumulated tool/thought transcript.
String runningSessionStatus(SessionExecution task) {
  String status;
  if (task.stopped) {
    status = '正在中断';
  } else if (task.decision != null) {
    status = '等待确认';
  } else if (task.holding) {
    status = task.pollOk ? '等待回复' : '正在恢复连接';
  } else {
    status = latestRunningActivity(task.activity);
    if (status.isEmpty) {
      status = switch (task.phase) {
        'repo' => '正在读取仓库',
        'agent' => '正在连接 Agent',
        'generate' => '正在生成回答',
        _ => '正在连接',
      };
    }
  }
  return task.queued.isEmpty ? status : '$status · ${task.queued.length} 条排队';
}

String latestRunningActivity(String activity) {
  final blocks = activity
      .trim()
      .split(RegExp(r'\r?\n\s*\r?\n'))
      .where((block) => block.trim().isNotEmpty);
  if (blocks.isEmpty) return '';
  final lines = blocks.last
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final head = lines.first.replaceAll(RegExp(r'[*`#_]'), '').trim();
  if (RegExp(r'^思考(?:[·\s]|$)').hasMatch(head)) return '正在思考';
  if (head == '跑脚本') {
    final elapsed = RegExp(r'已跑\s*\d+\s*(?:分\s*\d+\s*秒|秒|分)')
        .allMatches(lines.last)
        .lastOrNull
        ?.group(0);
    return elapsed == null ? '正在执行脚本' : '执行脚本 · $elapsed';
  }
  return head.replaceAll(RegExp(r'\s+'), ' ');
}
