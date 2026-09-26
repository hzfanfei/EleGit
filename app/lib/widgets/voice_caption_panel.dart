import 'package:flutter/material.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';

/// Subtitle for the TTS chunk currently playing (one speak segment from the server).
class VoiceCaptionPanel extends StatelessWidget {
  const VoiceCaptionPanel({
    super.key,
    required this.text,
    required this.palette,
    required this.maxWidth,
  });

  final String text;
  final ReaderPalette palette;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        elevation: 4,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(Wx.radius),
        color: palette.ink.withValues(alpha: 0.82),
        child: Container(
          key: const Key('wx-voice-caption'),
          constraints: BoxConstraints(maxWidth: maxWidth, minWidth: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(
            text,
            maxLines: 12,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.45,
              fontWeight: FontWeight.w500,
              color: palette.paper.withValues(alpha: 0.98),
              letterSpacing: 0.15,
            ),
          ),
        ),
      ),
    );
  }
}
