class VolcTtsVoice {
  const VolcTtsVoice({
    required this.id,
    required this.name,
    required this.scene,
  });

  final String id;
  final String name;
  final String scene;
}

const kDefaultVolcTtsVoice = 'zh_female_xiaohe_uranus_bigtts';

const kVolcTtsVoices = <VolcTtsVoice>[
  VolcTtsVoice(id: 'zh_female_xiaohe_uranus_bigtts', name: '小何 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_vv_uranus_bigtts', name: 'Vivi 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_m191_uranus_bigtts', name: '云舟 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_taocheng_uranus_bigtts', name: '小天 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_liufei_uranus_bigtts', name: '刘飞 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_sophie_uranus_bigtts', name: '魅力苏菲 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_qingxinnvsheng_uranus_bigtts', name: '清新女声 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_tianmeixiaoyuan_uranus_bigtts', name: '甜美小源 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_tianmeitaozi_uranus_bigtts', name: '甜美桃子 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_shuangkuaisisi_uranus_bigtts', name: '爽快思思 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_linjianvhai_uranus_bigtts', name: '邻家女孩 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_shaonianzixin_uranus_bigtts', name: '少年梓辛 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_wenroumama_uranus_bigtts', name: '温柔妈妈 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_jieshuoxiaoming_uranus_bigtts', name: '解说小明 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_linjiananhai_uranus_bigtts', name: '邻家男孩 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_ruyaqingnian_uranus_bigtts', name: '儒雅青年 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_gaolengyujie_uranus_bigtts', name: '高冷御姐 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_wenroushunv_uranus_bigtts', name: '温柔淑女 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_tiexinnvsheng_uranus_bigtts', name: '贴心女声 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_zhixingnv_uranus_bigtts', name: '知性女声 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_wenrouxiaoya_uranus_bigtts', name: '温柔小雅 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_male_shenyeboke_uranus_bigtts', name: '深夜播客 2.0', scene: '通用'),
  VolcTtsVoice(id: 'zh_female_kefunvsheng_uranus_bigtts', name: '暖阳女声 2.0', scene: '客服'),
  VolcTtsVoice(id: 'zh_female_xiaoxue_uranus_bigtts', name: '儿童绘本 2.0', scene: '有声阅读'),
  VolcTtsVoice(id: 'zh_female_liuchangnv_uranus_bigtts', name: '流畅女声 2.0', scene: '有声阅读'),
  VolcTtsVoice(id: 'zh_male_baqiqingshu_uranus_bigtts', name: '霸气青叔 2.0', scene: '有声阅读'),
];

final _voiceId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{2,79}$');

String sanitizeVolcTtsVoice(String? raw) {
  final voice = (raw ?? '').trim();
  if (!_voiceId.hasMatch(voice)) return '';
  return voice;
}

VolcTtsVoice resolveVolcTtsVoice(String? raw) {
  final id = sanitizeVolcTtsVoice(raw);
  if (id.isEmpty) return kVolcTtsVoices.first;
  for (final voice in kVolcTtsVoices) {
    if (voice.id == id) return voice;
  }
  return VolcTtsVoice(id: id, name: id, scene: '自定义');
}

List<MapEntry<String, List<VolcTtsVoice>>> get volcTtsVoiceGroups {
  final groups = <String, List<VolcTtsVoice>>{};
  for (final voice in kVolcTtsVoices) {
    groups.putIfAbsent(voice.scene, () => []).add(voice);
  }
  return groups.entries.toList();
}
