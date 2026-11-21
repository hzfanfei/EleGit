import 'package:flutter/material.dart';

import '../chat/running_sessions.dart';
import '../copy/running_status.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

class RunningSessionsPage extends StatelessWidget {
  const RunningSessionsPage({super.key, required this.running});
  final RunningSessions running;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
            child: Column(children: [
          WxPageHeader(
            title: '执行中',
            onBack: () => Navigator.of(context).pop(),
            trailing: [
              IconButton(
                tooltip: '关闭执行中',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const WxHairline(),
          Expanded(
              child: ListenableBuilder(
            listenable: running,
            builder: (context, _) {
              final tasks = running.active;
              if (tasks.isEmpty) return const Center(child: Text('暂无执行中的会话'));
              return ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: tasks.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) => _RunningSessionRow(
                  key: ValueKey('wx-running-${tasks[index].sessionId}'),
                  task: tasks[index],
                ),
              );
            },
          )),
        ])),
      );
}

class _RunningSessionRow extends StatelessWidget {
  const _RunningSessionRow({super.key, required this.task});
  final SessionExecution task;

  @override
  Widget build(BuildContext context) {
    final attention = task.decision != null || task.holding;
    final color = task.stopped
        ? Wx.muted
        : attention
            ? Wx.accent
            : Wx.ok;
    return SizedBox(
      height: 112,
      child: Material(
        color: Wx.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Wx.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pop(task),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SessionField(
                      label: '项目',
                      value: task.repo.repo.fullName,
                      color: Wx.text,
                      emphasized: true,
                    ),
                    const SizedBox(height: 6),
                    _SessionField(
                      label: '问题',
                      value: task.title.trim().isEmpty
                          ? '图片提问'
                          : task.title.replaceAll(RegExp(r'\s+'), ' ').trim(),
                      color: Wx.text,
                    ),
                    const SizedBox(height: 8),
                    _SessionField(
                      label: '状态',
                      value: runningSessionStatus(task),
                      valueKey: ValueKey('wx-running-status-${task.sessionId}'),
                      color: color,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: task.queued.isNotEmpty ? '中断并取消排队' : '中断',
                onPressed: task.stopped ? null : task.stop,
                icon: const Icon(Icons.stop_circle_outlined,
                    color: Wx.danger, size: 21),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SessionField extends StatelessWidget {
  const _SessionField({
    required this.label,
    required this.value,
    required this.color,
    this.emphasized = false,
    this.valueKey,
  });

  final String label;
  final String value;
  final Color color;
  final bool emphasized;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(
          width: 36,
          child: Text(label,
              style: const TextStyle(fontSize: 11, height: 1.3, color: Wx.muted)),
        ),
        Expanded(
          child: Text(value,
              key: valueKey,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: emphasized ? 14 : 12,
                height: 1.3,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
                color: color,
              )),
        ),
      ]);
}
