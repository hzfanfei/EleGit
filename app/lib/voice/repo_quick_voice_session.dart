import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/wenxiang_api.dart';
import '../copy/voice_stt_copy.dart';
import '../diagnostics/client_error_log.dart';
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
    this.onTurnRecorded,
    this.sttClient,
    this.voiceMedia,
    this.onError,
    this.resolveTtsVoice,
    this.resolveAgentMode,
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
  final Future<void> Function({
    required String question,
    required String answer,
    required String? originSessionId,
    String? engine,
    String? sessionId,
  })? onTurnRecorded;
  final void Function(String message)? onError;
  final String Function()? resolveTtsVoice;
  final bool Function()? resolveAgentMode;

  late final HoldToSpeakSession _hold;
  VoiceMedia? _media;
  bool _disposed = false;
  void _reportPlaybackError(Object error, StackTrace stack) {
    ClientErrorLog.instance.note(
      kind: 'voice-playback',
      message: error.toString(),
      summary: '问象快问快答播放失败 · $_voiceFormat/$_voiceCodec · ${_voiceRate}Hz',
      stack: stack.toString(),
    );
    onError?.call('播放失败：$error');
  }

  @override
  BookQuickVoicePhase phase = BookQuickVoicePhase.idle;
  String _thinkStatusLabel = '思考中…';
  _VoiceDestination? _destination;
  int _generation = 0;
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

  bool get belongsToSelectedSession =>
      !showsStatus || _destination?.sessionId == resolveSessionId();

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
        (phase == BookQuickVoicePhase.thinking ||
            phase == BookQuickVoicePhase.speaking) &&
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
    final destination = _captureDestination();
    if (_hold.sttBusy || busy || _hold.holding || _hold.holdPending) {
      await cancelActiveFlow();
    }
    if (_disposed) return;
    _destination = destination;
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

  void Function()? _playbackStartForCaption(String captionAtEnqueue, int generation) {
    if (captionAtEnqueue.isEmpty) return null;
    return () {
      if (_disposed || !_replyActive || generation != _generation) return;
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
    _generation++;
    _destination = null;
    _replyActive = false;
    api.cancelRepoVoiceTurn();
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

  _VoiceDestination _captureDestination() => _VoiceDestination(
        sessionId: resolveSessionId(),
        history: historyForVoice()
            .where((message) =>
                message.role != 'error' &&
                message.outcome != ChatTurnOutcome.queueCancelled)
            .toList(),
        agentMode: resolveAgentMode?.call() ?? false,
        ttsVoice: resolveTtsVoice?.call(),
      );

  Future<void> _onTranscript(String text) async {
    final question = text.trim();
    if (question.isEmpty) {
      _destination = null;
      phase = BookQuickVoicePhase.idle;
      onChanged();
      return;
    }
    final destination = _destination ??= _captureDestination();
    final generation = ++_generation;
    bool isCurrent() => !_disposed && generation == _generation;
    var replySessionId = destination.sessionId;
    _replyActive = true;
    _clearCaption();
    phase = BookQuickVoicePhase.thinking;
    _thinkStatusLabel = '思考中…';
    onChanged();

    _media ??= voiceMedia ?? DeviceVoiceMedia();
    _resetVoiceFormat();
    try {
      await _media!.stopPlayback();
      if (!isCurrent()) return;
      await for (final event in api.repoVoiceTurnStream(
        owner: owner,
        repo: repo,
        message: question,
        history: destination.history,
        sessionId: destination.sessionId,
        ttsVoice: destination.ttsVoice,
        agentMode: destination.agentMode,
      )) {
        if (!isCurrent()) break;
        if (event.type == 'meta') {
          replySessionId = event.sessionId ?? replySessionId;
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
            _media!
                .playPcm(
              event.pcm!,
              sampleRate: _voiceRate,
              format: _voiceFormat,
              codec: _voiceCodec,
              segmentCaption: captionAtEnqueue,
              onPlaybackStart:
                  _playbackStartForCaption(captionAtEnqueue, generation),
            )
                .catchError((Object err, StackTrace stack) {
              if (isCurrent()) _reportPlaybackError(err, stack);
            }),
          );
        } else if (event.type == 'done') {
          final answer = event.text.trim();
          replySessionId = event.sessionId ?? replySessionId;
          if (answer.isNotEmpty) {
            await onTurnRecorded?.call(
              question: question,
              answer: answer,
              engine: event.engine,
              originSessionId: destination.sessionId,
              sessionId: replySessionId,
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
    } catch (err, stack) {
      ClientErrorLog.instance.note(
        kind: 'voice-turn',
        message: err.toString(),
        summary: '问象快问快答回复中断',
        stack: stack.toString(),
      );
      if (isCurrent()) onError?.call(err.toString());
    } finally {
      if (isCurrent() && _replyActive) {
        phase = BookQuickVoicePhase.speaking;
        onChanged();
        try {
          await _media?.waitForPlaybackQueue();
        } catch (err, stack) {
          if (isCurrent()) _reportPlaybackError(err, stack);
        }
      }
      if (isCurrent()) {
        _replyActive = false;
        _destination = null;
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
    api.cancelRepoVoiceTurn();
    _resetVoiceFormat();
    _clearCaption();
    unawaited(_media?.stopPlayback());
    _hold.dispose();
    _media?.dispose();
  }
}

class _VoiceDestination {
  const _VoiceDestination({
    required this.sessionId,
    required this.history,
    required this.agentMode,
    required this.ttsVoice,
  });

  final String? sessionId;
  final List<ChatMessage> history;
  final bool agentMode;
  final String? ttsVoice;
}
