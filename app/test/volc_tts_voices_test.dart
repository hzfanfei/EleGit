import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/volc_tts_voices.dart';

void main() {
  test('default Volcengine voice is 小何 2.0', () {
    expect(kDefaultVolcTtsVoice, 'zh_female_xiaohe_uranus_bigtts');
    expect(resolveVolcTtsVoice(null).id, kDefaultVolcTtsVoice);
    expect(resolveVolcTtsVoice('').id, kDefaultVolcTtsVoice);
    expect(resolveVolcTtsVoice('zh_male_m191_uranus_bigtts').id, 'zh_male_m191_uranus_bigtts');
    expect(resolveVolcTtsVoice('zh_male_m191_uranus_bigtts').name, contains('云舟'));
  });

  test('catalog is official seed-tts-2.0 speakers grouped for the picker', () {
    expect(kVolcTtsVoices.first.id, kDefaultVolcTtsVoice);
    expect(kVolcTtsVoices.map((v) => v.id).toSet().length, kVolcTtsVoices.length);
    expect(kVolcTtsVoices.any((v) => v.id == 'zh_female_vv_uranus_bigtts'), isTrue);
    expect(volcTtsVoiceGroups, isNotEmpty);
    expect(sanitizeVolcTtsVoice('zh_female_xiaohe_uranus_bigtts'), 'zh_female_xiaohe_uranus_bigtts');
    expect(sanitizeVolcTtsVoice('http://x'), '');
  });
}
