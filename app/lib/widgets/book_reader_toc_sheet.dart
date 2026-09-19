import 'package:flutter/material.dart';

import '../models.dart';
import '../theme.dart';

class BookReaderTocSheet extends StatelessWidget {
  const BookReaderTocSheet({
    super.key,
    required this.toc,
    required this.currentIndex,
    required this.onPick,
  });

  final List<BookTocEntry> toc;
  final int currentIndex;
  final void Function(int chapterIndex) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Wx.raised,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Wx.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 14, Wx.inset, 8),
              child: Text('目录', style: theme.textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 24),
                itemCount: toc.length,
                itemBuilder: (context, i) {
                  final entry = toc[i];
                  final title = entry.title.trim().isEmpty
                      ? '第 ${entry.index + 1} 章'
                      : entry.title.trim();
                  final active = entry.index == currentIndex;
                  final pad = Wx.inset + (entry.level.clamp(0, 6) * 14);
                  return ListTile(
                    contentPadding: EdgeInsets.fromLTRB(pad, 0, Wx.inset, 0),
                    title: Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                        fontSize: entry.level > 0 ? 14 : 15,
                        color: active ? Wx.accent : null,
                      ),
                    ),
                    onTap: () => onPick(entry.index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
