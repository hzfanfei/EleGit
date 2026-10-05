class MinimaxTtsVoice {
  const MinimaxTtsVoice({
    required this.id,
    required this.name,
    required this.scene,
  });

  final String id;
  final String name;
  final String scene;
}

const kDefaultMinimaxTtsVoice = 'female-shaonv';

const kMinimaxTtsVoices = <MinimaxTtsVoice>[
  MinimaxTtsVoice(id: 'female-shaonv', name: '少女音色', scene: '中文女声'),
  MinimaxTtsVoice(id: 'female-yujie', name: '御姐音色', scene: '中文女声'),
  MinimaxTtsVoice(id: 'female-chengshu', name: '成熟女性音色', scene: '中文女声'),
  MinimaxTtsVoice(id: 'female-tianmei', name: '甜美女性音色', scene: '中文女声'),
  MinimaxTtsVoice(id: 'tianxin_xiaoling', name: '甜心小玲', scene: '中文女声'),
  MinimaxTtsVoice(id: 'male-qn-qingse', name: '青涩青年音色', scene: '中文男声'),
  MinimaxTtsVoice(id: 'male-qn-jingying', name: '精英青年音色', scene: '中文男声'),
  MinimaxTtsVoice(id: 'junlang_nanyou', name: '俊朗男友', scene: '中文男声'),
];

MinimaxTtsVoice resolveMinimaxTtsVoice(String? raw) {
  final id = (raw ?? '').trim();
  for (final voice in kMinimaxTtsVoices) {
    if (voice.id == id) return voice;
  }
  return kMinimaxTtsVoices.first;
}
