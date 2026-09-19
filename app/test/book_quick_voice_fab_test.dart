import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/persist/book_reader_prefs.dart';
import 'package:wenxiang/voice/book_quick_voice_session.dart';
import 'package:wenxiang/voice/hold_to_speak_session.dart';
import 'package:wenxiang/widgets/book_quick_voice_fab.dart';

import 'support/fake_api.dart';

class _MockQuickVoiceSession implements QuickVoiceFabHost {
  _MockQuickVoiceSession(this.hold);

  @override
  BookQuickVoicePhase phase = BookQuickVoicePhase.speaking;

  @override
  final HoldToSpeakSession hold;

  @override
  bool showsStatus = true;

  @override
  String statusLabel = '播放中…';

  @override
  String voiceCaption = '正在读这一句。';

  @override
  bool showsVoiceCaption = true;

  @override
  bool tapToCancelActive = true;

  int cancelCalls = 0;
  int pointerDownCalls = 0;
  int pointerUpCalls = 0;

  @override
  Future<void> cancelActiveFlow() async {
    cancelCalls += 1;
    voiceCaption = '';
    showsVoiceCaption = false;
    phase = BookQuickVoicePhase.idle;
  }

  @override
  Future<void> pointerDown(double globalY) async {
    pointerDownCalls += 1;
    tapToCancelActive = false;
    phase = BookQuickVoicePhase.listening;
  }

  @override
  void pointerMove(double globalY) {}

  @override
  Future<void> pointerUp() async {
    pointerUpCalls += 1;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows caption panel above mic', (tester) async {
    const palette = ReaderPalette(
      paper: Color(0xFFF7F4EE),
      ink: Color(0xFF2C2824),
      muted: Color(0xFF7A7368),
      chromeFade: Color(0xFFF7F4EE),
    );
    final api = FakeWenxiangApi();
    final session = _MockQuickVoiceSession(
      HoldToSpeakSession(
        api: api,
        onChanged: () {},
        onTranscript: (_) {},
        onError: (_) {},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: BookQuickVoiceFab(
              session: session,
              palette: palette,
              enabled: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('wx-voice-caption')), findsOneWidget);
    expect(find.text('正在读这一句。'), findsOneWidget);
    expect(find.byKey(const Key('wx-wait-ms')), findsNothing);
  });

  testWidgets('shows a ticking ms timer above the status chip while waiting', (tester) async {
    const palette = ReaderPalette(
      paper: Color(0xFFF7F4EE),
      ink: Color(0xFF2C2824),
      muted: Color(0xFF7A7368),
      chromeFade: Color(0xFFF7F4EE),
    );
    final api = FakeWenxiangApi();
    final session = _MockQuickVoiceSession(
      HoldToSpeakSession(
        api: api,
        onChanged: () {},
        onTranscript: (_) {},
        onError: (_) {},
      ),
    )
      ..phase = BookQuickVoicePhase.thinking
      ..statusLabel = '思考中…'
      ..showsVoiceCaption = false
      ..voiceCaption = ''
      ..tapToCancelActive = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: BookQuickVoiceFab(
              session: session,
              palette: palette,
              enabled: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('wx-wait-ms')), findsOneWidget);
    final first = tester.widget<Text>(find.byKey(const Key('wx-wait-ms-text'))).data;
    await tester.pump(const Duration(milliseconds: 80));
    final second = tester.widget<Text>(find.byKey(const Key('wx-wait-ms-text'))).data;
    expect(first, isNotEmpty);
    expect(second, isNotEmpty);
    expect(second, isNot(first));
  });

  testWidgets('tap mic cancels active flow', (tester) async {
    const palette = ReaderPalette(
      paper: Color(0xFFF7F4EE),
      ink: Color(0xFF2C2824),
      muted: Color(0xFF7A7368),
      chromeFade: Color(0xFFF7F4EE),
    );
    final api = FakeWenxiangApi();
    final session = _MockQuickVoiceSession(
      HoldToSpeakSession(
        api: api,
        onChanged: () {},
        onTranscript: (_) {},
        onError: (_) {},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: BookQuickVoiceFab(
              key: const Key('wx-quick-voice-fab'),
              session: session,
              palette: palette,
              enabled: true,
            ),
          ),
        ),
      ),
    );

    final micButton = find.byKey(const Key('wx-quick-voice-mic'));
    expect(micButton, findsOneWidget);
    final center = tester.getCenter(micButton);
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump();

    expect(session.cancelCalls, 1);
    expect(session.pointerDownCalls, 0);
  });

  testWidgets('long-press while answering interrupts and starts a new hold', (tester) async {
    const palette = ReaderPalette(
      paper: Color(0xFFF7F4EE),
      ink: Color(0xFF2C2824),
      muted: Color(0xFF7A7368),
      chromeFade: Color(0xFFF7F4EE),
    );
    final api = FakeWenxiangApi();
    final session = _MockQuickVoiceSession(
      HoldToSpeakSession(
        api: api,
        onChanged: () {},
        onTranscript: (_) {},
        onError: (_) {},
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: BookQuickVoiceFab(
              session: session,
              palette: palette,
              enabled: true,
            ),
          ),
        ),
      ),
    );

    final center = tester.getCenter(find.byKey(const Key('wx-quick-voice-mic')));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.pointerDownCalls, 1);
    expect(session.cancelCalls, 0);
    await gesture.up();
    await tester.pump();
    expect(session.pointerUpCalls, 1);
    expect(session.cancelCalls, 0);
  });
}
