import 'dart:async';

import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/voice_stt_copy.dart';
import 'background_work.dart';
import 'device_media.dart';
import 'voice_media.dart';
import 'voice_client.dart';
import 'voice_stt_client.dart';

/// Push-to-talk STT session shared by chat and book-ask UIs.
class HoldToSpeakSession {
  HoldToSpeakSession({
    required this.api,
    this.sttClient,
    this.voiceMedia,
    required this.onChanged,
    required this.onTranscript,
    required this.onError,
  });

  final WenxiangApi api;
  final VoiceSttClient? sttClient;
  final VoiceMedia? voiceMedia;
  final VoidCallback onChanged;
  final void Function(String text) onTranscript;
  final void Function(String message) onError;

  bool holding = false;
  bool holdPending = false;
  bool holdCancel = false;
  bool sttBusy = false;
  String holdLive = '';
  String holdHint = '';

  VoiceSttClient? _stt;
  StreamSubscription<VoiceEvent>? _sttSub;
  StreamSubscription<List<int>>? _micSub;
  VoiceMedia? _media;
  double _holdStartY = 0;
  bool _backgroundHeld = false;

  bool get active => holding || holdPending || sttBusy;

  void _holdBackground() {
    if (_backgroundHeld) return;
    _backgroundHeld = true;
    unawaited(BackgroundWork.acquire(microphone: true));
  }

  void _freeBackground() {
    if (!_backgroundHeld) return;
    _backgroundHeld = false;
    unawaited(BackgroundWork.release(microphone: true));
  }

  Future<void> beginHold(double globalY) async {
    if (sttBusy || holding || holdPending) return;
    holdPending = true;
    _holdStartY = globalY;
    holdHint = '松开发送，上滑取消';
    onChanged();

    final client = sttClient ?? SocketSttClient(api.sttUri());
    _stt = client;
    _sttSub = client.connect().listen(_onSttEvent, onError: (err) {
      _fail(humanizeSttConnectionError(err));
    });
    client.start();

    final media = voiceMedia ?? _media ?? DeviceVoiceMedia();
    _media = media;
    final allowed = await media.requestMic();
    if (!allowed) {
      _disposeStt();
      holdPending = false;
      holdHint = '';
      onChanged();
      onError('需要麦克风才能说话');
      return;
    }
    _holdBackground();
    _micSub = media.startMic().listen(client.sendPcm, onError: (_) {
      _fail('需要麦克风才能说话');
    });
    HapticFeedback.mediumImpact();
    holding = true;
    holdPending = false;
    holdCancel = false;
    holdLive = '';
    onChanged();
  }

  void moveHold(double globalY) {
    if (!holding && !holdPending) return;
    final cancel = _holdStartY - globalY > 72;
    if (cancel == holdCancel) return;
    holdCancel = cancel;
    holdHint = cancel ? '松开取消' : '松开发送，上滑取消';
    onChanged();
  }

  Future<void> endHold() async {
    if (!holding && !holdPending && _stt == null) return;
    final cancel = holdCancel;
    final pendingOnly = holdPending && _stt == null;
    holding = false;
    holdPending = false;
    holdCancel = false;
    holdHint = '';
    onChanged();

    if (pendingOnly) {
      holdLive = '';
      onChanged();
      return;
    }
    await _micSub?.cancel();
    _micSub = null;
    await _media?.stopMic();
    if (cancel) {
      _stt?.cancel();
      _disposeStt();
      holdLive = '';
      onChanged();
      return;
    }
    sttBusy = true;
    holdHint = '识别中，点按取消';
    onChanged();
    _stt?.stop();
  }

  /// Cancel in-flight recognition after [endHold] (tap pad or live chip).
  Future<void> cancelRecognition() async {
    if (!sttBusy && _stt == null) return;
    await abortHold();
  }

  void _onSttEvent(VoiceEvent event) {
    if (event.type == 'error') {
      _fail(humanizeSttEvent(code: event.code, hint: event.hint));
      return;
    }
    if (event.type == 'caption' && event.text.isNotEmpty) {
      holdLive = event.text;
      onChanged();
    }
    if (event.type == 'done') {
      final text = event.text.trim();
      _disposeStt();
      sttBusy = false;
      holdLive = '';
      holdHint = '';
      onChanged();
      if (text.isNotEmpty) {
        onTranscript(text);
      } else {
        onError(humanizeSttEvent(code: 'empty'));
      }
    }
    if (event.type == 'cancelled') {
      _disposeStt();
      sttBusy = false;
      holdLive = '';
      holdHint = '';
      onChanged();
    }
  }

  void _fail(String message) {
    _disposeStt();
    sttBusy = false;
    holding = false;
    holdLive = '';
    holdHint = '';
    onChanged();
    onError(message);
  }

  void _disposeStt() {
    _freeBackground();
    _sttSub?.cancel();
    _sttSub = null;
    _stt?.dispose();
    _stt = null;
  }

  /// Drop mic/STT without sending a transcript (e.g. tap-to-cancel).
  Future<void> abortHold() async {
    holding = false;
    holdPending = false;
    holdCancel = false;
    holdLive = '';
    holdHint = '';
    sttBusy = false;
    await _micSub?.cancel();
    _micSub = null;
    await _media?.stopMic();
    _stt?.cancel();
    _disposeStt();
    onChanged();
  }

  void dispose() {
    _micSub?.cancel();
    _micSub = null;
    _media?.stopMic();
    _disposeStt();
  }
}
