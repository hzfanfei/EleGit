import 'dart:async';

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../api/wenxiang_api.dart';
import '../copy/voice_stt_copy.dart';
import '../models.dart';
import '../persist/book_chat_store.dart';
import 'device_media.dart';
import 'hold_to_speak_session.dart';
import 'voice_media.dart';
import 'voice_stt_client.dart';

enum BookQuickVoicePhase { idle, listening, recognizing, thinking, speaking }

/// Shared surface for [BookQuickVoiceFab] (book + repo quick voice).
abstract class QuickVoiceFabHost {
  BookQuickVoicePhase get phase;
  HoldToSpeakSession get hold;
  bool get showsStatus;
  String get statusLabel;
  /// Spoken answer lines revealed in sync with TTS chunks (may be empty).
  String get voiceCaption;
  bool get showsVoiceCaption;
  Future<void> pointerDown(double globalY);
  void pointerMove(double globalY);
  Future<void> pointerUp();

  /// True while a quick tap should cancel (not start a new hold).
  bool get tapToCancelActive;

  Future<void> cancelActiveFlow();
}

/// Hold-to-talk book Q&A with spoken replies only (no on-screen transcript).
class BookQuickVoiceSession implements QuickVoiceFabHost {
  BookQuickVoiceSession({
    required this.api,
    required this.bookId,
    required this.chapterHint,
    required this.onChanged,
    required this.readingPlace,
    required this.historyForVoice,
    this.onTurnRecorded,
    this.sttClient,
    this.voiceMedia,
    this.onError,
  }) {
    _hold = HoldToSpeakSession(
      api: api,
      sttClient: sttClient,
      voiceMedia: voiceMedia,
      onChanged: _handleHoldChanged,
      onTranscript: (text) => unawaited(_onTranscript(text)),
      onError: (message) {
        phase = BookQuickVoicePhase.idle;
        onChanged();
        onError?.call(message);
      },
    );
  }

  final WenxiangApi api;
  final String bookId;
  String chapterHint;
  final VoiceSttClient? sttClient;
  final VoiceMedia? voiceMedia;
  final VoidCallback onChanged;
  final BookReadingPlace Function() readingPlace;
  final List<ChatMessage> Function(BookReadingPlace place) historyForVoice;
  final Future<void> Function({
    required BookReadingPlace place,
    required String question,
    required String answer,
    String? engine,
    String? sessionId,
  })? onTurnRecorded;
  final void Function(String message)? onError;

  late final HoldToSpeakSession _hold;
  VoiceMedia? _media;
  bool _disposed = false;
  BookQuickVoicePhase phase = BookQuickVoicePhase.idle;
  String _thinkStatusLabel = '思考中…';
  String? _sessionId;
  bool _replyActive = false;
  int _voiceRate = 24000;
  String _voiceFormat = 'pcm';
  String _voiceCodec = 'raw';
  /// Text for the TTS part whose audio is currently being received (server: caption then audio).
  String _segmentCaption = '';
  String _voiceCaption = '';

  HoldToSpeakSession get hold => _hold;

  @override
  String get voiceCaption => _voiceCaption;

  @override
  bool get showsVoiceCaption =>
      _voiceCaption.isNotEmpty &&
      phase != BookQuickVoicePhase.listening &&
      phase != BookQuickVoicePhase.recognizing;

  bool get busy =>
      _replyActive ||
      phase == BookQuickVoicePhase.thinking ||
      phase == BookQuickVoicePhase.speaking;

  bool get showsStatus =>
      phase != BookQuickVoicePhase.idle ||
      _hold.holding ||
      _hold.holdPending ||
      _hold.sttBusy;

  String get statusLabel {
    final hold = _hold;
    if (hold.holding && hold.holdCancel) return '松开取消';
    if (hold.holdPending) return '准备中…';
    switch (phase) {
      case BookQuickVoicePhase.listening:
        return hold.holdHint.isNotEmpty ? hold.holdHint : '正在听…';
      case BookQuickVoicePhase.recognizing:
        return '识别中…';
      case BookQuickVoicePhase.thinking:
        return _thinkStatusLabel;
      case BookQuickVoicePhase.speaking:
        return '播放中…';
      case BookQuickVoicePhase.idle:
        if (hold.sttBusy) return '识别中…';
        return '';
    }
  }

  void _handleHoldChanged() {
    if (_hold.holding) {
      phase = BookQuickVoicePhase.listening;
    } else if (_hold.sttBusy) {
      phase = BookQuickVoicePhase.recognizing;
    } else if (!_replyActive &&
        phase != BookQuickVoicePhase.thinking &&
        phase != BookQuickVoicePhase.speaking) {
      phase = BookQuickVoicePhase.idle;
    }
    onChanged();
  }

  Future<void> pointerDown(double globalY) async {
    if (_hold.sttBusy) return;
    if (busy) interruptReply();
    phase = BookQuickVoicePhase.listening;
    onChanged();
    await _hold.beginHold(globalY);
  }

  void pointerMove(double globalY) => _hold.moveHold(globalY);

  Future<void> pointerUp() async {
    if (_hold.holding || _hold.holdPending) {
      phase = BookQuickVoicePhase.recognizing;
      onChanged();
    }
    await _hold.endHold();
    if (!_replyActive &&
        !_hold.sttBusy &&
        !_hold.holding &&
        phase != BookQuickVoicePhase.thinking &&
        phase != BookQuickVoicePhase.speaking) {
      phase = BookQuickVoicePhase.idle;
      onChanged();
    }
  }

  void _resetVoiceFormat() {
    _voiceRate = 24000;
    _voiceFormat = 'pcm';
    _voiceCodec = 'raw';
  }

  void _clearCaption() {
    _segmentCaption = '';
    _voiceCaption = '';
  }

  void _onCaptionSegment(String text) {
    final chunk = text.trim();
    if (chunk.isEmpty) return;
    _segmentCaption = chunk;
  }

  void Function()? _playbackStartForCaption(String captionAtEnqueue) {
    if (captionAtEnqueue.isEmpty) return null;
    return () {
      if (_disposed || !_replyActive) return;
      _voiceCaption = captionAtEnqueue;
      onChanged();
    };
  }

  @override
  bool get tapToCancelActive =>
      !_hold.holding &&
      !_hold.holdPending &&
      (_replyActive ||
          _hold.sttBusy ||
          phase == BookQuickVoicePhase.thinking ||
          phase == BookQuickVoicePhase.speaking ||
          phase == BookQuickVoicePhase.recognizing);

  @override
  Future<void> cancelActiveFlow() async {
    if (_disposed) return;
    _replyActive = false;
    api.cancelBookVoiceTurn();
    _resetVoiceFormat();
    _clearCaption();
    phase = BookQuickVoicePhase.idle;
    onChanged();
    await _media?.stopPlayback();
    await _hold.abortHold();
  }

  void interruptReply() {
    unawaited(cancelActiveFlow());
  }

  Future<void> _onTranscript(String text) async {
    final question = text.trim();
    if (question.isEmpty) {
      phase = BookQuickVoicePhase.idle;
      onChanged();
      return;
    }
    _replyActive = true;
    _clearCaption();
    phase = BookQuickVoicePhase.thinking;
    _thinkStatusLabel = '思考中…';
    onChanged();

    _media ??= voiceMedia ?? DeviceVoiceMedia();
    _resetVoiceFormat();
    await _media!.stopPlayback();
    final place = readingPlace();
    final history = historyForVoice(place).where((m) => m.role != 'error').toList();
    try {
      await for (final event in api.bookVoiceTurnStream(
        bookId: bookId,
        message: question,
        history: history,
        sessionId: _sessionId,
        chapter: chapterHint,
      )) {
        if (!_replyActive) break;
        if (event.type == 'meta') {
          _sessionId = event.sessionId ?? _sessionId;
        } else if (event.type == 'state') {
          final serverPhase = event.phase?.trim() ?? '';
          if (serverPhase == 'speak') {
            phase = BookQuickVoicePhase.speaking;
            onChanged();
          } else if (serverPhase == 'connect') {
            phase = BookQuickVoicePhase.thinking;
            _thinkStatusLabel = '连接中…';
            onChanged();
          } else if (serverPhase == 'think') {
            phase = BookQuickVoicePhase.thinking;
            _thinkStatusLabel = '思考中…';
            onChanged();
          }
        } else if (event.type == 'caption' && event.text.isNotEmpty) {
          _onCaptionSegment(event.text);
        } else if (event.type == 'audio' &&
            event.pcm != null &&
            event.pcm!.isNotEmpty) {
          final captionAtEnqueue = _segmentCaption;
          _voiceRate = event.sampleRate ?? _voiceRate;
          _voiceFormat = event.audioFormat ?? _voiceFormat;
          _voiceCodec = event.codec ?? _voiceCodec;
          phase = BookQuickVoicePhase.speaking;
          onChanged();
          unawaited(
            _media!.playPcm(
              event.pcm!,
              sampleRate: _voiceRate,
              format: _voiceFormat,
              codec: _voiceCodec,
              segmentCaption: captionAtEnqueue,
              onPlaybackStart: _playbackStartForCaption(captionAtEnqueue),
            ).catchError((Object err) {
              if (_replyActive) onError?.call('播放失败：$err');
            }),
          );
        } else if (event.type == 'done') {
          final answer = event.text.trim();
          _sessionId = event.sessionId ?? _sessionId;
          if (answer.isNotEmpty) {
            await onTurnRecorded?.call(
              place: place,
              question: question,
              answer: answer,
              engine: event.engine,
              sessionId: _sessionId,
            );
          }
        } else if (event.type == 'error') {
          onError?.call(
            humanizeSttEvent(code: event.code, hint: event.hint ?? event.error),
          );
        }
      }
    } on OperationCancelled {
      // user interrupted
    } catch (err) {
      onError?.call(err.toString());
    } finally {
      if (_replyActive && !_disposed) {
        phase = BookQuickVoicePhase.speaking;
        onChanged();
        try {
          await _media?.waitForPlaybackQueue();
        } catch (err) {
          if (!_disposed) onError?.call('播放失败：$err');
        }
      }
      _replyActive = false;
      if (!_disposed) {
        _clearCaption();
        phase = BookQuickVoicePhase.idle;
        onChanged();
      }
    }
  }

  @visibleForTesting
  Future<void> runVoiceTurnForTest(String question) => _onTranscript(question);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _replyActive = false;
    api.cancelBookVoiceTurn();
    _resetVoiceFormat();
    _clearCaption();
    unawaited(_media?.stopPlayback());
    _hold.dispose();
    _media?.dispose();
  }
}
