import 'package:flutter/material.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';

/// Reading chrome — TOC, settings, progress; fades for immersion.
class BookReaderChrome extends StatelessWidget {
  const BookReaderChrome({
    super.key,
    required this.title,
    required this.chapter,
    required this.progressLabel,
    required this.palette,
    required this.onBack,
    required this.onOpenToc,
    required this.onOpenSettings,
  });

  final String title;
  final String chapter;
  final String progressLabel;
  final ReaderPalette palette;
  final VoidCallback onBack;
  final VoidCallback onOpenToc;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            palette.chromeFade.withValues(alpha: 0.97),
            palette.chromeFade.withValues(alpha: 0.78),
            Colors.transparent,
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    tooltip: '返回书库',
                    onPressed: onBack,
                    icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: palette.ink),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.2,
                              color: palette.ink,
                            ),
                          ),
                          if (chapter.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              chapter,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: palette.muted,
                                fontSize: 12,
                                letterSpacing: 0.15,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '目录',
                    onPressed: onOpenToc,
                    icon: Icon(Icons.menu_book_outlined, color: palette.ink),
                  ),
                  IconButton(
                    tooltip: '阅读设置',
                    onPressed: onOpenSettings,
                    icon: Icon(Icons.text_fields_rounded, color: palette.ink),
                  ),
                ],
              ),
              if (progressLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Wx.inset, 4, Wx.inset, 0),
                  child: Text(
                    progressLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: palette.muted,
                      fontSize: 11,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
