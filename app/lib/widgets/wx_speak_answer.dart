import 'dart:async';

import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../voice/device_media.dart';
import '../voice/voice_media.dart';
import 'wx_rich_text.dart';

/// One spoken summary at a time. Tapping another answer stops the current one.
class AnswerSpeech extends ChangeNotifier {
  AnswerSpeech({VoiceMedia? media}) : _media = media;

  static final shared = AnswerSpeech();

  VoiceMedia? _media;
  int _token = 0;
  String? activeId;
  bool thinking = false;
  bool playing = false;

  VoiceMedia get media => _media ??= DeviceVoiceMedia();

  bool thinkingFor(String id) => activeId == id && thinking;
  bool playingFor(String id) => activeId == id && playing;

  Future<void> toggle({
    required String id,
    required String text,
    required WenxiangApi api,
    String? ttsVoice,
    void Function(String message)? onError,
  }) async {
    if (activeId == id && (thinking || playing)) {
      await stop(api);
      return;
    }
    await stop(api);
    final token = ++_token;
    activeId = id;
    thinking = true;
    playing = false;
    notifyListeners();
    try {
      await for (final event in api.speakSummaryStream(text: text, ttsVoice: ttsVoice)) {
        if (token != _token) return;
        if (event.type == 'state' && event.phase == 'speak') {
          thinking = false;
          playing = true;
          notifyListeners();
        } else if (event.type == 'audio' && event.pcm != null && event.pcm!.isNotEmpty) {
          thinking = false;
          playing = true;
          notifyListeners();
          unawaited(
            media.playPcm(
              event.pcm!,
              sampleRate: event.sampleRate ?? 24000,
              format: event.audioFormat ?? 'pcm',
              codec: event.codec ?? 'raw',
            ),
          );
        } else if (event.type == 'error') {
          onError?.call(
            (event.hint ?? event.error ?? '').trim().isEmpty
                ? '没能朗读这段回答'
                : (event.hint ?? event.error)!,
          );
          await stop(api);
          return;
        }
      }
      if (token != _token) return;
      await media.waitForPlaybackQueue();
    } on OperationCancelled {
      // Stopped, or replaced by another answer.
    } catch (err) {
      if (token == _token) {
        final message = err.toString().trim();
        onError?.call(message.isEmpty || message == 'cancelled' ? '没能朗读这段回答' : message);
      }
    } finally {
      if (token == _token) {
        activeId = null;
        thinking = false;
        playing = false;
        notifyListeners();
      }
    }
  }

  Future<void> stop(WenxiangApi api) async {
    _token += 1;
    activeId = null;
    thinking = false;
    playing = false;
    notifyListeners();
    api.cancelSpeakSummary();
    await _media?.stopPlayback();
  }
}

/// Speaker on the left of the copy button. Asks for a spoken summary, then plays it.
class WxAnswerActions extends StatelessWidget {
  const WxAnswerActions({
    super.key,
    required this.text,
    required this.api,
    this.ttsVoice,
    this.speech,
  });

  final String text;
  final WenxiangApi api;
  final String? ttsVoice;
  final AnswerSpeech? speech;

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SpeakAnswerButton(
            text: text,
            api: api,
            ttsVoice: ttsVoice,
            speech: speech ?? AnswerSpeech.shared,
          ),
          WxCopyAnswerButton(text: text, bare: true),
        ],
      ),
    );
  }
}

class _SpeakAnswerButton extends StatefulWidget {
  const _SpeakAnswerButton({
    required this.text,
    required this.api,
    required this.speech,
    this.ttsVoice,
  });

  final String text;
  final WenxiangApi api;
  final String? ttsVoice;
  final AnswerSpeech speech;

  @override
  State<_SpeakAnswerButton> createState() => _SpeakAnswerButtonState();
}

class _SpeakAnswerButtonState extends State<_SpeakAnswerButton> {
  late final String _id = 'speak-${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    widget.speech.addListener(_onSpeech);
  }

  @override
  void didUpdateWidget(covariant _SpeakAnswerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speech != widget.speech) {
      oldWidget.speech.removeListener(_onSpeech);
      widget.speech.addListener(_onSpeech);
    }
  }

  @override
  void dispose() {
    widget.speech.removeListener(_onSpeech);
    super.dispose();
  }

  void _onSpeech() {
    if (mounted) setState(() {});
  }

  Future<void> _toggle() async {
    await widget.speech.toggle(
      id: _id,
      text: widget.text,
      api: widget.api,
      ttsVoice: widget.ttsVoice,
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(message), duration: const Duration(milliseconds: 1600)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final thinking = widget.speech.thinkingFor(_id);
    final playing = widget.speech.playingFor(_id);
    return IconButton(
      tooltip: playing || thinking ? '停止朗读' : '朗读总结',
      onPressed: () => unawaited(_toggle()),
      icon: thinking
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: Wx.muted),
            )
          : Icon(
              playing ? Icons.volume_up : Icons.volume_up_outlined,
              size: 18,
              color: playing ? Wx.accent : Wx.muted,
            ),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    );
  }
}
