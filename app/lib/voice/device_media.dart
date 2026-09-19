import 'dart:async';

import 'dart:io';

import 'dart:typed_data';



import 'package:audioplayers/audioplayers.dart';

import 'package:permission_handler/permission_handler.dart';

import 'package:record/record.dart';



import 'android_media_audio.dart';
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

            audioFocus: AndroidAudioFocus.gain,

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

            audioFocus: AndroidAudioFocus.gain,

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

  }) async {

    if (pcm.isEmpty) return;

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

    _queue.add(_PlayJob(bytes: bytes, format: outFormat));

    await _drain();

  }



  _PlayJob _takeNextJob() {
    final first = _queue.removeAt(0);
    if (first.format == 'mp3' || _queue.isEmpty || _queue.first.format != 'pcm') {
      return first;
    }
    final parts = <Uint8List>[first.bytes];
    while (_queue.isNotEmpty && _queue.first.format == 'pcm') {
      parts.add(_queue.removeAt(0).bytes);
    }
    if (parts.length == 1) return first;
    final total = parts.fold<int>(0, (sum, b) => sum + b.length);
    final merged = Uint8List(total);
    var offset = 0;
    for (final part in parts) {
      merged.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return _PlayJob(bytes: merged, format: 'pcm');
  }

  Future<void> _playJob(_PlayJob job) async {

    await _player.stop();

    await _player.setVolume(1);

    await _player.setPlayerMode(PlayerMode.mediaPlayer);



    final completer = Completer<void>();

    late final StreamSubscription<PlayerState> sub;

    sub = _player.onPlayerStateChanged.listen((state) {

      if (state == PlayerState.completed) {

        unawaited(sub.cancel());

        if (!completer.isCompleted) completer.complete();

      }

    });



    try {

      if (job.format == 'mp3') {

        await _player.play(

          BytesSource(job.bytes, mimeType: 'audio/mpeg'),

        );

      } else {

        await _player.play(

          BytesSource(pcm16ToWav(job.bytes, sampleRate: _outRate)),

        );

      }

      await completer.future.timeout(const Duration(minutes: 3));

    } finally {

      await sub.cancel();

    }

  }



  Future<void> _drain() async {

    if (_playing) return;

    _playing = true;

    try {

      await _preparePlaybackAudio();

      while (_queue.isNotEmpty) {

        await _playJob(_takeNextJob());

      }

    } finally {

      _playing = false;

      if (_queue.isNotEmpty) {

        unawaited(_drain());

      }

    }

  }



  @override
  Future<void> waitForPlaybackQueue() async {
    while (_playing || _queue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  @override

  Future<void> stopPlayback() async {

    _queue.clear();

    await _player.stop();

    _playing = false;

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

  _PlayJob({required this.bytes, required this.format});



  final Uint8List bytes;

  final String format;

}


