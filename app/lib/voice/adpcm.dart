import 'dart:typed_data';

/// Call audio from the companion as IMA ADPCM, 4 bits a sample. Raw 24 kHz PCM
/// was 384 kbps and stalled on the tunnel; this is a quarter of that.
///
/// Packet: "WXA1" | sampleRate u32le | sampleCount u32le | predictor i16le | index u8 | 0 | nibbles (low first)
const int adpcmHeaderBytes = 16;

const List<int> _indexTable = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];
const List<int> _stepTable = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107,
  118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
  6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
  32767,
];

bool isAdpcmPacket(List<int> bytes) {
  return bytes.length >= adpcmHeaderBytes &&
      bytes[0] == 0x57 &&
      bytes[1] == 0x58 &&
      bytes[2] == 0x41 &&
      bytes[3] == 0x31;
}

class AdpcmAudio {
  AdpcmAudio(this.pcm, this.sampleRate);

  final Uint8List pcm;
  final int sampleRate;
}

AdpcmAudio? decodeAdpcm(Uint8List packet) {
  if (!isAdpcmPacket(packet)) return null;
  final head = ByteData.sublistView(packet, 0, adpcmHeaderBytes);
  final sampleRate = head.getUint32(4, Endian.little);
  final count = head.getUint32(8, Endian.little);
  if (packet.length < adpcmHeaderBytes + ((count + 1) >> 1)) return null;
  var predictor = head.getInt16(12, Endian.little);
  var index = head.getUint8(14);
  final out = Uint8List(count * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < count; i += 1) {
    final byte = packet[adpcmHeaderBytes + (i >> 1)];
    final code = i.isOdd ? byte >> 4 : byte & 15;
    final step = _stepTable[index];
    var delta = step >> 3;
    if (code & 4 != 0) delta += step;
    if (code & 2 != 0) delta += step >> 1;
    if (code & 1 != 0) delta += step >> 2;
    predictor = (code & 8 != 0 ? predictor - delta : predictor + delta).clamp(-32768, 32767).toInt();
    index = (index + _indexTable[code]).clamp(0, 88).toInt();
    view.setInt16(i * 2, predictor, Endian.little);
  }
  return AdpcmAudio(out, sampleRate);
}
