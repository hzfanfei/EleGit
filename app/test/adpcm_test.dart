import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/adpcm.dart';

/// Encoded and decoded by server/src/adpcm.js; the phone must match it exactly.
const _packet =
    'V1hBMcBdAADwAAAAAAA2AHAjgKkocyOB28uJEAHazasJEYLJvIpSNBOQmUFGMwKoqjA1BMjMq4gRoN3LmhAigNqbOEYzApgJczQTgLuKMTWQ7buqAALKzbsZMiOg2wpkNCOAmSBVMwG5rQkxAurNugkQgNq8izBEApiaQFVDAZCJIUUSmLyrCA==';
const _decoded =
    'oAApCbIRPhdAGFYX1xQNEV0QfhN5FzwfACcLLMou9S2nKBQhBRrFEXEObw1ZDtgQHhPOE60QawpBAUb28Os75ZPhr+K15XTonuzc68zpKuRY3e7WxNIC0nPVVdyV5FnsaPMn9vz2tvSm8sbwevIi90X/QQmlEi4buiC8IdIgqBzeGG0VDRYIGrkfByU6Kw8sTSsaJZodhhT9C3EGbwWFBAQHSgn6CdkGlwBt9+Tu6OQz3ovap9ut3kLjbOcu6H7nXeQb3kfYAdZR1bLZGOEs6rXyefqE/24Amf9T/UP74/ve/6EHnREBG4oj3ibgJ/YmIiHUG2MYwxd3GRYdQSISJ7In/iVNIHMWDw2GBPr+7/nZ+q77eP8oAAf96PdV8EHnuN701u7TrdbX2iXg9uQX6KjoEubJ4hXe9NqF2y3gUOhM8rD7OQTFCccK3QleBxgFyAXpCCsPVRjeIKIoqCuSLBMqxSQyHScYaBU9FoMYVB11IAYhcB5UGCoPLwTN/Gnzwe/d8N/xnvRz9bH0QPFe6h7iWtpL02HSNtOE2LfeN+ZC6yzsV+sR6aDlwONR5Pno2+/w+VQDTw69EhQUTBX4EfIOCA6HEFEU5Bv4JBErZS5jLaQqJCMVHKsVgRG/EG8R';

void main() {
  test('decodes the companion\'s ADPCM exactly like the server', () {
    final audio = decodeAdpcm(base64Decode(_packet));
    expect(audio, isNotNull);
    expect(audio!.sampleRate, 24000);
    expect(base64Encode(audio.pcm), _decoded);
  });

  test('leaves plain PCM and MP3 alone', () {
    expect(decodeAdpcm(base64Decode('AAABAAIAAwA=')), isNull);
    expect(isAdpcmPacket([0x49, 0x44, 0x33, 0x04]), isFalse);
  });
}
