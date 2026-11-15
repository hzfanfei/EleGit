import 'package:flutter/material.dart';

import '../chat/running_sessions.dart';
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
                padding: const EdgeInsets.all(Wx.inset),
                itemCount: tasks.length,
                separatorBuilder: (context, index) => const WxHairline(),
                itemBuilder: (context, index) {
                  final task = tasks[index];
                  return ListTile(
                    key: ValueKey('wx-running-${task.sessionId}'),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    leading: Icon(
                        task.decision != null ? Icons.help_outline : Icons.sync,
                        color: task.decision != null ? Wx.accent : Wx.ok),
                    title: Text(task.title,
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${task.repo.repo.fullName} · '
                        '${task.stopped ? '正在中断' : task.decision != null ? '等待确认' : task.holding ? '等待回复' : '运行中'}'
                        '${task.queued.isEmpty ? '' : ' · ${task.queued.length} 条排队'}'
                        '${task.activity.isEmpty ? '' : '\n${task.activity}'}'),
                    onTap: () => Navigator.of(context).pop(task),
                    trailing: IconButton(
                      tooltip: '中断',
                      onPressed: task.stopped ? null : task.stop,
                      icon: const Icon(Icons.stop_circle_outlined,
                          color: Wx.danger),
                    ),
                  );
                },
              );
            },
          )),
        ])),
      );
}
