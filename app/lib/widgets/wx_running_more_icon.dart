import 'package:flutter/material.dart';

import '../chat/running_sessions.dart';

/// Shares the same live count as the running sessions list across projects.
class WxRunningMoreIcon extends StatelessWidget {
  const WxRunningMoreIcon({super.key, required this.running});

  final RunningSessions running;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: running,
        builder: (context, _) {
          final count = running.active.length;
          if (count == 0) return const Icon(Icons.more_horiz);
          return Semantics(
            label: '$count 个会话执行中',
            child: Badge(
              key: const Key('wx-running-count'),
              label: Text('$count'),
              child: const Icon(Icons.more_horiz),
            ),
          );
        },
      );
}
