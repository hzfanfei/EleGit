import 'dart:async';

import 'dart:io';

import 'dart:typed_data';



import 'package:audioplayers/audioplayers.dart';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:record/record.dart';



import 'android_media_audio.dart';
import 'background_work.dart';
import 'voice_media.dart';



class DeviceVoiceMedia implements VoiceMedia {

  /// Full-duplex phone call uses telephony capture; quick-voice STT uses normal mic + media playback.
  DeviceVoiceMedia({this.telephonyCapture = false}) {

    unawaited(_player.setReleaseMode(ReleaseMode.stop));

  }

  final bool telephonyCapture;



  final AudioRecorder _recorder = AudioRecorder();

  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Uint8List>? _micSub;

  bool _playing = false;

  int _pendingPlayCalls = 0;

  Completer<void>? _currentPlay;

  int _outRate = 24000;



  @override

  Future<bool> requestMic() async {

    final status = await Permission.microphone.request();

    if (status.isGranted || status.isLimited) return true;

    return _recorder.hasPermission();

  }



  @override

  Stream<Uint8List> startMic() {

    final controller = StreamController<Uint8List>();

    () async {

      try {

        if (Platform.isIOS || telephonyCapture) {

          await _prepareCallAudio();

        } else {

          await AndroidMediaAudio.resetToMediaPlayback();

        }

        final stream = await _recorder.startStream(

          RecordConfig(

            encoder: AudioEncoder.pcm16bits,

            sampleRate: 16000,

            numChannels: 1,

            echoCancel: true,

            noiseSuppress: true,

            androidConfig: telephonyCapture

                ? const AndroidRecordConfig(

                    audioSource: AndroidAudioSource.voiceCommunication,

                    speakerphone: true,

                    audioManagerMode: AudioManagerMode.modeInCommunication,

                  )

                : const AndroidRecordConfig(

                    audioSource: AndroidAudioSource.mic,

                    speakerphone: false,

                    manageBluetooth: false,

                    audioManagerMode: AudioManagerMode.modeNormal,

                  ),

          ),

        );

        _micSub = stream.listen(controller.add, onError: controller.addError, onDone: controller.close);

      } catch (err) {

        controller.addError(err);

        await controller.close();

      }

    }();

    return controller.stream;

  }



  @override

  Future<void> stopMic() async {

    await _micSub?.cancel();

    _micSub = null;

    if (await _recorder.isRecording()) {

      await _recorder.stop();

    }

    await _exitTelephonyRoute();

  }



  Future<void> _exitTelephonyRoute() async {

    if (Platform.isAndroid && !telephonyCapture) {

      await AndroidMediaAudio.resetToMediaPlayback();

    }

    await _preparePlaybackAudio();

  }



  Future<void> _prepareCallAudio() async {

    try {

      await AudioPlayer.global.setAudioContext(

        AudioContext(

          android: AudioContextAndroid(

            isSpeakerphoneOn: true,

            stayAwake: true,

            contentType: AndroidContentType.speech,

            usageType: AndroidUsageType.voiceCommunication,

            // Leaving the app must not pause the in-app call.
            audioFocus: AndroidAudioFocus.none,

          ),

          iOS: AudioContextIOS(

            category: AVAudioSessionCategory.playAndRecord,

            options: {

              AVAudioSessionOptions.defaultToSpeaker,

              AVAudioSessionOptions.allowBluetooth,

              AVAudioSessionOptions.mixWithOthers,

            },

          ),

        ),

      );

    } catch (_) {

      // Desktop tests and missing platform views still record.

    }

  }



  final List<_PlayJob> _queue = [];



  static bool _looksLikeMp3(Uint8List bytes) {

    if (bytes.length < 3) return false;

    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true;

    if (bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0) return true;

    return false;

  }



  Future<void> _preparePlaybackAudio() async {

    try {

      if (Platform.isAndroid && !telephonyCapture) {

        await AndroidMediaAudio.resetToMediaPlayback();

      }

      await AudioPlayer.global.setAudioContext(

        AudioContext(

          android: AudioContextAndroid(

            isSpeakerphoneOn: telephonyCapture,

            audioMode: AndroidAudioMode.normal,

            stayAwake: true,

            contentType: AndroidContentType.music,

            usageType: AndroidUsageType.media,

            // Leaving the app must not pause MediaPlayer via focus loss.
            audioFocus: AndroidAudioFocus.none,

          ),

          iOS: AudioContextIOS(

            category: AVAudioSessionCategory.playback,

            options: {

              AVAudioSessionOptions.defaultToSpeaker,

              AVAudioSessionOptions.mixWithOthers,

            },

          ),

        ),

      );

    } catch (_) {}

  }



  @override

  Future<void> playPcm(

    Uint8List pcm, {

    int sampleRate = 24000,

    String format = 'pcm',

    String codec = 'raw',

    String segmentCaption = '',

    void Function()? onPlaybackStart,

  }) async {

    if (pcm.isEmpty) return;

    _pendingPlayCalls += 1;

    try {

    await _preparePlaybackAudio();

    _outRate = sampleRate;

    var bytes = Uint8List.fromList(pcm);

    if (format == 'pcm' && codec == 'gzip') {

      bytes = Uint8List.fromList(gzip.decode(bytes));

    }

    var outFormat = format;

    if (outFormat == 'pcm' && _looksLikeMp3(bytes)) {

      outFormat = 'mp3';

    }

    if (outFormat == 'pcm') {
      bytes = amplifyPcm16(bytes);
    }

    _queue.add(
      _PlayJob(
        bytes: bytes,
        format: outFormat,
        segmentCaption: segmentCaption,
        onPlaybackStart: onPlaybackStart,
      ),
    );

    await _drain();

    } finally {

      _pendingPlayCalls -= 1;

    }

  }



  _PlayJob _takeNextJob() {
    final first = _queue.removeAt(0);
    if (first.format == 'mp3' || _queue.isEmpty || _queue.first.format != 'pcm') {
      return first;
    }
    final mergedJobs = <_PlayJob>[first];
    while (_queue.isNotEmpty &&
        _queue.first.format == 'pcm' &&
        _queue.first.segmentCaption == first.segmentCaption) {
      mergedJobs.add(_queue.removeAt(0));
    }
    if (mergedJobs.length == 1) return first;
    final total = mergedJobs.fold<int>(0, (sum, j) => sum + j.bytes.length);
    final merged = Uint8List(total);
    var offset = 0;
    for (final job in mergedJobs) {
      merged.setRange(offset, offset + job.bytes.length, job.bytes);
      offset += job.bytes.length;
    }
    void Function()? onStart;
    for (final job in mergedJobs) {
      onStart ??= job.onPlaybackStart;
    }
    return _PlayJob(
      bytes: merged,
      format: 'pcm',
      segmentCaption: first.segmentCaption,
      onPlaybackStart: onStart,
    );
  }

  Future<void> _playJob(_PlayJob job, {required bool leadingStop}) async {
    job.onPlaybackStart?.call();

    final cancel = Completer<void>();
    _currentPlay = cancel;

    try {
      if (job.format == 'mp3') {
        if (job.bytes.isEmpty) return;
        await _playSourceWithRetry(
          BytesSource(job.bytes, mimeType: 'audio/mpeg'),
          leadingStop: leadingStop,
        );
      } else {
        final pcm = normalizePcm16Length(job.bytes);
        if (pcm.isEmpty) return;
        final wav = pcm16ToWav(pcm, sampleRate: _outRate);
        if (wav.isEmpty) return;
        await _playSourceWithRetry(
          BytesSource(wav, mimeType: 'audio/wav'),
          fileFallbackBytes: Platform.isAndroid ? wav : null,
          leadingStop: leadingStop,
        );
      }
      await Future.any([
        _player.onPlayerComplete.first,
        cancel.future,
      ]).timeout(const Duration(minutes: 3));
    } on TimeoutException {
      if (cancel.isCompleted) return;
      rethrow;
    } catch (_) {
      if (cancel.isCompleted) return;
      rethrow;
    } finally {
      if (identical(_currentPlay, cancel)) _currentPlay = null;
    }
  }

  /// Android MediaPlayer sometimes rejects back-to-back [BytesSource] after [stop].
  Future<void> _playSourceWithRetry(
    Source source, {
    Uint8List? fileFallbackBytes,
    required bool leadingStop,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (leadingStop || attempt > 0) {
          await _player.stop();
          if (Platform.isAndroid) {
            await Future<void>.delayed(Duration(milliseconds: 40 * (attempt + 1)));
          }
        }
        await _player.setVolume(1);
        await _player.setPlayerMode(PlayerMode.mediaPlayer);
        Source active = source;
        if (attempt > 0 && fileFallbackBytes != null && fileFallbackBytes.isNotEmpty) {
          final dir = await getTemporaryDirectory();
          final file = File(
            '${dir.path}/wx_tts_${DateTime.now().microsecondsSinceEpoch}.wav',
          );
          await file.writeAsBytes(fileFallbackBytes, flush: true);
          active = DeviceFileSource(file.path);
        }
        await _player.play(active);
        return;
      } on PlatformException catch (err) {
        lastError = err;
      } catch (err) {
        lastError = err;
      }
    }
    if (lastError != null) throw lastError!;
    throw StateError('playback failed');
  }



  Future<void> _drain() async {

    if (_playing) return;

    _playing = true;

    await BackgroundWork.acquire();

    try {

      await _preparePlaybackAudio();

      var leadingStop = true;
      while (_queue.isNotEmpty) {
        await _playJob(_takeNextJob(), leadingStop: leadingStop);
        leadingStop = false;
      }

    } finally {

      await BackgroundWork.release();

      _playing = false;

      if (_queue.isNotEmpty) {

        unawaited(_drain());

      }

    }

  }



  @override
  Future<void> waitForPlaybackQueue() async {
    while (_playing || _queue.isNotEmpty || _pendingPlayCalls > 0) {
      if (!_playing && _queue.isNotEmpty) {
        unawaited(_drain());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  @override

  Future<void> stopPlayback() async {

    _queue.clear();

    final play = _currentPlay;

    if (play != null && !play.isCompleted) play.complete();

    await _player.stop();

  }



  @override

  void dispose() {

    unawaited(stopMic());

    unawaited(stopPlayback());

    unawaited(_recorder.dispose());

    unawaited(_player.dispose());

  }

}



class _PlayJob {

  _PlayJob({
    required this.bytes,
    required this.format,
    this.segmentCaption = '',
    this.onPlaybackStart,
  });



  final Uint8List bytes;

  final String format;

  final String segmentCaption;

  final void Function()? onPlaybackStart;

}


