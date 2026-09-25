class XiaomiTtsVoice {
  const XiaomiTtsVoice({
    required this.id,
    required this.name,
    required this.scene,
  });

  final String id;
  final String name;
  final String scene;
}

const kDefaultXiaomiTtsVoice = 'bingtang';

const kXiaomiTtsVoices = <XiaomiTtsVoice>[
  XiaomiTtsVoice(id: 'bingtang', name: '冰糖', scene: '中文女声'),
  XiaomiTtsVoice(id: 'moli', name: '茉莉', scene: '中文女声'),
  XiaomiTtsVoice(id: 'suda', name: '苏打', scene: '中文女声'),
  XiaomiTtsVoice(id: 'baihua', name: '白桦', scene: '中文男声'),
  XiaomiTtsVoice(id: 'mia', name: 'Mia', scene: '英文女声'),
  XiaomiTtsVoice(id: 'chloe', name: 'Chloe', scene: '英文女声'),
  XiaomiTtsVoice(id: 'milo', name: 'Milo', scene: '英文男声'),
  XiaomiTtsVoice(id: 'dean', name: 'Dean', scene: '英文男声'),
  XiaomiTtsVoice(id: 'mimo_default', name: '默认', scene: '默认'),
];

XiaomiTtsVoice resolveXiaomiTtsVoice(String? raw) {
  final id = (raw ?? '').trim();
  for (final voice in kXiaomiTtsVoices) {
    if (voice.id == id) return voice;
  }
  return kXiaomiTtsVoices.first;
}
