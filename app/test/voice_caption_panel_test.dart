import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/persist/book_reader_prefs.dart';
import 'package:wenxiang/widgets/voice_caption_panel.dart';

void main() {
  testWidgets('VoiceCaptionPanel shows current line only', (tester) async {
    const palette = ReaderPalette(
      paper: Color(0xFFF7F4EE),
      ink: Color(0xFF2C2824),
      muted: Color(0xFF7A7368),
      chromeFade: Color(0xFFF7F4EE),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: VoiceCaptionPanel(
            text: '正在读这一句。',
            palette: palette,
            maxWidth: 220,
          ),
        ),
      ),
    );
    expect(find.byKey(const Key('wx-voice-caption')), findsOneWidget);
    expect(find.text('正在读这一句。'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsNothing);
  });
}
