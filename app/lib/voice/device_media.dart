import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'voice_media.dart';

class DeviceVoiceMedia implements VoiceMedia {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription<Uint8List>? _micSub;
  final List<Uint8List> _queue = [];
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
        final stream = await _recorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: 16000,
            numChannels: 1,
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
  }

  @override
  Future<void> playPcm(Uint8List pcm, {int sampleRate = 24000}) async {
    if (pcm.isEmpty) return;
    _outRate = sampleRate;
    _queue.add(Uint8List.fromList(pcm));
    await _drain();
  }

  Future<void> _drain() async {
    if (_playing) return;
    _playing = true;
    try {
      while (_queue.isNotEmpty) {
        final chunk = _queue.removeAt(0);
        await _player.play(BytesSource(pcm16ToWav(chunk, sampleRate: _outRate)));
        await _player.onPlayerComplete.first;
      }
    } finally {
      _playing = false;
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
