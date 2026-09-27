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

  int _micEpoch = 0;

  Future<void> _micChain = Future<void>.value();

  bool _playing = false;

  /// Bumped by [stopPlayback]. In-flight [playPcm] must not enqueue after this.
  int _playbackEpoch = 0;

  int _pendingPlayCalls = 0;

  Completer<void>? _currentPlay;

  int _outRate = 24000;



  @override

  Future<bool> requestMic() async {

    final status = await Permission.microphone.request();

    if (status.isGranted || status.isLimited) return true;

    return _recorder.hasPermission();

  }



  Future<void> _enqueueMic(Future<void> Function() action) {

    final run = _micChain.then((_) => action());

    _micChain = run.then((_) {}, onError: (_) {});

    return run;

  }



  /// The record plugin throws this when stop races a create or a dispose.

  Future<void> _stopRecorderQuietly() async {

    try {

      if (await _recorder.isRecording()) {

        await _recorder.stop();

      }

    } on PlatformException {

      // Not created yet, or the native recorder was already disposed.

    }

  }



  Future<void> _openMic(int epoch, StreamController<Uint8List> controller) async {

    try {

      if (Platform.isIOS || telephonyCapture) {

        await _prepareCallAudio();

      } else {

        await AndroidMediaAudio.resetToMediaPlayback();

      }

      if (epoch != _micEpoch) {

        await controller.close();

        return;

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

        if (epoch != _micEpoch) {

          await _stopRecorderQuietly();

          await controller.close();

          return;

        }

        _micSub = stream.listen(controller.add, onError: controller.addError, onDone: controller.close);

      } catch (err) {

        if (epoch == _micEpoch) controller.addError(err);

        await controller.close();

      }

  }



  @override

  Stream<Uint8List> startMic() {

    final epoch = ++_micEpoch;

    final controller = StreamController<Uint8List>();

    unawaited(_enqueueMic(() => _openMic(epoch, controller)));

    return controller.stream;

  }



  @override

  Future<void> stopMic() async {

    _micEpoch++;

    await _enqueueMic(() async {

      await _micSub?.cancel();

      _micSub = null;

      await _stopRecorderQuietly();

      await _exitTelephonyRoute();

    });

  }



  Future<void> _exitTelephonyRoute() async {

    await _preparePlaybackAudio(leaveCall: true);

  }



  /// Call route is set once. Resetting it on every spoken chunk drops the mic.
  bool _callRouteReady = false;



  Future<void> _prepareCallAudio() async {

    if (_callRouteReady) return;

    try {

      await AudioPlayer.global.setAudioContext(

        AudioContext(

          android: AudioContextAndroid(

            isSpeakerphoneOn: true,

            stayAwake: true,

            contentType: AndroidContentType.speech,

            usageType: AndroidUsageType.voiceCommunication,

            audioMode: AndroidAudioMode.inCommunication,

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

      _callRouteReady = true;

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



  Future<void> _preparePlaybackAudio({bool leaveCall = false}) async {

    if (telephonyCapture && !leaveCall) {

      await _prepareCallAudio();

      return;

    }

    _callRouteReady = false;

    try {

      if (Platform.isAndroid && (leaveCall || !telephonyCapture)) {

        await AndroidMediaAudio.resetToMediaPlayback();

      }

      await AudioPlayer.global.setAudioContext(

        AudioContext(

          android: AudioContextAndroid(

            isSpeakerphoneOn: false,

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

    final epoch = _playbackEpoch;

    _pendingPlayCalls += 1;

    try {

    await _preparePlaybackAudio();

    if (epoch != _playbackEpoch) return;

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

    if (epoch != _playbackEpoch) return;

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

  Future<void> _playJob(
    _PlayJob job, {
    required bool leadingStop,
    required int epoch,
  }) async {
    if (epoch != _playbackEpoch) return;
    job.onPlaybackStart?.call();

    final cancel = Completer<void>();
    _currentPlay = cancel;
    final done = Completer<void>();
    final completeSub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });

    try {
      if (epoch != _playbackEpoch) return;
      if (job.format == 'mp3') {
        if (job.bytes.isEmpty) return;
        await _playSourceWithRetry(
          BytesSource(job.bytes, mimeType: 'audio/mpeg'),
          leadingStop: leadingStop,
          epoch: epoch,
        );
      } else {
        final pcm = normalizePcm16Length(job.bytes);
        if (pcm.isEmpty) return;
        final wav = pcm16ToWav(pcm, sampleRate: _outRate);
        if (wav.isEmpty) return;
        if (epoch != _playbackEpoch) return;
        await _playSourceWithRetry(
          BytesSource(wav, mimeType: 'audio/wav'),
          fileFallbackBytes: Platform.isAndroid ? wav : null,
          leadingStop: leadingStop,
          epoch: epoch,
        );
      }
      await Future.any([
        done.future,
        cancel.future,
      ]).timeout(playbackCompleteBudget(
        byteLength: job.bytes.length,
        sampleRate: _outRate,
        format: job.format,
      ));
    } on TimeoutException {
      if (cancel.isCompleted) return;
      try {
        await _player.stop();
      } on PlatformException {
        // already stopped
      }
    } catch (_) {
      if (cancel.isCompleted) return;
      rethrow;
    } finally {
      await completeSub.cancel();
      if (identical(_currentPlay, cancel)) _currentPlay = null;
    }
  }

  /// Android MediaPlayer sometimes rejects back-to-back [BytesSource] after [stop].
  Future<void> _playSourceWithRetry(
    Source source, {
    Uint8List? fileFallbackBytes,
    required bool leadingStop,
    required int epoch,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (epoch != _playbackEpoch) return;
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
        if (epoch != _playbackEpoch) return;
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

    final epoch = _playbackEpoch;

    _playing = true;

    await BackgroundWork.acquire();

    try {

      await _preparePlaybackAudio();

      if (epoch != _playbackEpoch) return;

      var leadingStop = true;
      while (_queue.isNotEmpty && epoch == _playbackEpoch) {
        await _playJob(_takeNextJob(), leadingStop: leadingStop, epoch: epoch);
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

    _playbackEpoch += 1;

    _queue.clear();

    final play = _currentPlay;

    if (play != null && !play.isCompleted) play.complete();

    try {

      await _player.stop();

    } on PlatformException {

      // Player was not prepared, or already disposed.

    }

  }



  @override

  void dispose() {

    unawaited(_shutdown());

  }



  Future<void> _shutdown() async {

    await stopMic();

    await stopPlayback();

    try {

      await _recorder.dispose();

    } on PlatformException {

      // Already gone.

    }

    try {

      await _player.dispose();

    } on PlatformException {

      // Already gone.

    }

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


