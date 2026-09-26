import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';

/// [BookReaderChrome] below the status bar: outer padding, the 48px toolbar
/// (title + chapter can run a hair past the icons), and the progress line.
/// Content uses this same inset whether the bar is showing, so a tap does not
/// move the book and the chapter title is not painted under the gradient.
const kReaderChromeBodyHeight = 84.0;

/// List padding under the reader chrome. Uses the larger of padding and
/// viewPadding so an open IME cannot zero [MediaQueryData.padding.top] and
/// drop text into the status-bar region.
double bookReaderTopContentPad({required MediaQueryData media}) {
  final top = media.viewPadding.top > media.padding.top ? media.viewPadding.top : media.padding.top;
  return top + kReaderChromeBodyHeight;
}

/// Status / nav bar style for the reader. Paper-colored status bar + no
/// contrast scrim: OEM IME / immersive transitions otherwise flash a white
/// strip on sepia and light paper.
SystemUiOverlayStyle bookReaderSystemOverlayStyle(ReaderSettings settings) {
  final dark = settings.theme == ReaderThemeMode.dark;
  final paper = settings.palette.paper;
  final base = dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
  return base.copyWith(
    statusBarColor: paper,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemStatusBarContrastEnforced: false,
    systemNavigationBarContrastEnforced: false,
  );
}

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
            palette.paper.withValues(alpha: 0.94),
            palette.paper.withValues(alpha: 0.72),
            palette.paper.withValues(alpha: 0),
          ],
          stops: const [0, 0.42, 1],
        ),
      ),
      child: SafeArea(
        bottom: false,
        minimum: EdgeInsets.only(top: MediaQuery.viewPaddingOf(context).top),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(2, 2, 2, 10),
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
