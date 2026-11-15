import 'package:flutter/material.dart';

import '../chat/running_sessions.dart';
import '../theme.dart';

/// A shared floating entry, placed above the page without covering its controls.
class WxRunningSessionsButton extends StatelessWidget {
  const WxRunningSessionsButton({
    super.key,
    required this.running,
    required this.onPressed,
  });

  final RunningSessions running;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: SafeArea(
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ListenableBuilder(
                listenable: running,
                builder: (context, _) {
                  final count = running.active.length;
                  if (count == 0) return const SizedBox.shrink();
                  return Tooltip(
                    message: '执行中：$count 个会话',
                    child: Material(
                      color: Wx.surface,
                      elevation: 6,
                      shape: const CircleBorder(),
                      child: InkWell(
                        key: const Key('wx-running-float'),
                        customBorder: const CircleBorder(),
                        onTap: onPressed,
                        child: Semantics(
                          button: true,
                          label: '$count 个会话执行中',
                          child: SizedBox.square(
                            dimension: 48,
                            child: Center(
                              child: Badge(
                                key: const Key('wx-running-count'),
                                label: Text('$count'),
                                child: const Icon(Icons.dynamic_feed_outlined,
                                    color: Wx.accent),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
}
