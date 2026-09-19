import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/wenxiang_api.dart';
import '../copy/voice_stt_copy.dart';
import '../models.dart';
import 'book_quick_voice_session.dart';
import 'device_media.dart';
import 'hold_to_speak_session.dart';
import 'voice_media.dart';
import 'voice_stt_client.dart';

/// Hold-to-talk repo Q&A with spoken replies only (same UX as book quick voice).
class RepoQuickVoiceSession implements QuickVoiceFabHost {
  RepoQuickVoiceSession({
    required this.api,
    required this.owner,
    required this.repo,
    required this.onChanged,
    required this.historyForVoice,
    required this.resolveSessionId,
    this.onSessionId,
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
  final String owner;
  final String repo;
  final VoiceSttClient? sttClient;
  final VoiceMedia? voiceMedia;
  final VoidCallback onChanged;
  final List<ChatMessage> Function() historyForVoice;
  final String? Function() resolveSessionId;
  final void Function(String? id)? onSessionId;
  final Future<void> Function({
    required String question,
    required String answer,
    String? engine,
    String? sessionId,
  })? onTurnRecorded;
  final void Function(String message)? onError;

  late final HoldToSpeakSession _hold;
  VoiceMedia? _media;
  @override
  BookQuickVoicePhase phase = BookQuickVoicePhase.idle;
  String _thinkStatusLabel = '思考中…';
  String? _sessionId;
  bool _replyActive = false;
  int _voiceRate = 24000;
  String _voiceFormat = 'pcm';
  String _voiceCodec = 'raw';
  String _segmentCaption = '';
  String _voiceCaption = '';

  @override
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

  @override
  bool get showsStatus =>
      phase != BookQuickVoicePhase.idle ||
      _hold.holding ||
      _hold.holdPending ||
      _hold.sttBusy;

  @override
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
    if (_replyActive &&
        (phase == BookQuickVoicePhase.thinking || phase == BookQuickVoicePhase.speaking) &&
        _hold.holding) {
      interruptReply();
    }
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

  @override
  Future<void> pointerDown(double globalY) async {
    if (_hold.sttBusy) return;
    if (busy) interruptReply();
    phase = BookQuickVoicePhase.listening;
    onChanged();
    await _hold.beginHold(globalY);
  }

  @override
  void pointerMove(double globalY) => _hold.moveHold(globalY);

  @override
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
      if (!_replyActive) return;
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
    api.cancelRepoVoiceTurn();
    _resetVoiceFormat();
    _clearCaption();
    unawaited(_media?.stopPlayback());
    await _hold.abortHold();
    _replyActive = false;
    phase = BookQuickVoicePhase.idle;
    onChanged();
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
    final history = historyForVoice().where((m) => m.role != 'error').toList();
    final sid = _sessionId ?? resolveSessionId();
    try {
      await for (final event in api.repoVoiceTurnStream(
        owner: owner,
        repo: repo,
        message: question,
        history: history,
        sessionId: sid,
      )) {
        if (!_replyActive) break;
        if (event.type == 'meta') {
          _sessionId = event.sessionId ?? _sessionId;
          onSessionId?.call(_sessionId);
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
          onSessionId?.call(_sessionId);
          if (answer.isNotEmpty) {
            await onTurnRecorded?.call(
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
      if (_replyActive) {
        phase = BookQuickVoicePhase.speaking;
        onChanged();
        try {
          await _media?.waitForPlaybackQueue();
        } catch (err) {
          onError?.call('播放失败：$err');
        }
      }
      _replyActive = false;
      _clearCaption();
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
