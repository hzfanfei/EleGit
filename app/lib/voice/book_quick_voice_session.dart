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

/// Hold-to-talk book Q&A with spoken replies only (no on-screen transcript).
class BookQuickVoiceSession {
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
  BookQuickVoicePhase phase = BookQuickVoicePhase.idle;
  String _thinkStatusLabel = '思考中…';
  String? _sessionId;
  bool _replyActive = false;
  final List<Uint8List> _pendingVoicePcm = [];
  int _pendingVoiceRate = 24000;
  String _pendingVoiceFormat = 'pcm';
  String _pendingVoiceCodec = 'raw';

  HoldToSpeakSession get hold => _hold;

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

  void _clearPendingVoice() {
    _pendingVoicePcm.clear();
    _pendingVoiceRate = 24000;
    _pendingVoiceFormat = 'pcm';
    _pendingVoiceCodec = 'raw';
  }

  Future<void> _flushPendingVoice() async {
    if (_pendingVoicePcm.isEmpty || _media == null) return;
    final rate = _pendingVoiceRate;
    final format = _pendingVoiceFormat;
    final codec = _pendingVoiceCodec;
    final total = _pendingVoicePcm.fold<int>(0, (sum, b) => sum + b.length);
    final merged = Uint8List(total);
    var offset = 0;
    for (final part in _pendingVoicePcm) {
      merged.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    _clearPendingVoice();
    await _media!.playPcm(
      merged,
      sampleRate: rate,
      format: format,
      codec: codec,
    );
  }

  void interruptReply() {
    api.cancelBookVoiceTurn();
    _clearPendingVoice();
    unawaited(_media?.stopPlayback());
    _replyActive = false;
    if (phase == BookQuickVoicePhase.speaking || phase == BookQuickVoicePhase.thinking) {
      phase = BookQuickVoicePhase.idle;
      onChanged();
    }
  }

  Future<void> _onTranscript(String text) async {
    final question = text.trim();
    if (question.isEmpty) {
      phase = BookQuickVoicePhase.idle;
      onChanged();
      return;
    }
    _replyActive = true;
    phase = BookQuickVoicePhase.thinking;
    _thinkStatusLabel = '思考中…';
    onChanged();

    _media ??= voiceMedia ?? DeviceVoiceMedia();
    _clearPendingVoice();
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
        } else if (event.type == 'audio' &&
            event.pcm != null &&
            event.pcm!.isNotEmpty) {
          _pendingVoicePcm.add(event.pcm!);
          _pendingVoiceRate = event.sampleRate ?? _pendingVoiceRate;
          _pendingVoiceFormat = event.audioFormat ?? _pendingVoiceFormat;
          _pendingVoiceCodec = event.codec ?? _pendingVoiceCodec;
          phase = BookQuickVoicePhase.speaking;
          onChanged();
        } else if (event.type == 'done') {
          try {
            await _flushPendingVoice();
          } catch (err) {
            onError?.call('播放失败：$err');
            break;
          }
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
      _replyActive = false;
      phase = BookQuickVoicePhase.idle;
      onChanged();
    }
  }

  void dispose() {
    interruptReply();
    _hold.dispose();
    _media?.dispose();
  }
}
