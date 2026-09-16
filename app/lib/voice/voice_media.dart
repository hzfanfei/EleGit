import 'dart:typed_data';

abstract class VoiceMedia {
  Future<bool> requestMic();
  Stream<Uint8List> startMic();
  Future<void> stopMic();
  Future<void> playPcm(Uint8List pcm, {int sampleRate = 24000});
  Future<void> stopPlayback();
  void dispose();
}

class FakeVoiceMedia implements VoiceMedia {
  FakeVoiceMedia({this.micGranted = true});

  bool micGranted;
  int requestCalls = 0;
  int startCalls = 0;
  int stopMicCalls = 0;
  int stopPlayCalls = 0;
  final List<Uint8List> played = [];

  @override
  Future<bool> requestMic() async {
    requestCalls += 1;
    return micGranted;
  }

  @override
  Stream<Uint8List> startMic() {
    startCalls += 1;
    return const Stream.empty();
  }

  @override
  Future<void> stopMic() async {
    stopMicCalls += 1;
  }

  @override
  Future<void> playPcm(Uint8List pcm, {int sampleRate = 24000}) async {
    played.add(pcm);
  }

  @override
  Future<void> stopPlayback() async {
    stopPlayCalls += 1;
  }

  @override
  void dispose() {}
}

Uint8List pcm16ToWav(Uint8List pcm, {int sampleRate = 24000, int channels = 1}) {
  final byteRate = sampleRate * channels * 2;
  final data = ByteData(44 + pcm.length);
  final bytes = data.buffer.asUint8List();
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, 44 + pcm.length, pcm);
  return bytes;
}
