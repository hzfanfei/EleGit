/** Official MiniMax system voices. Source: platform.minimaxi.com 系统音色列表. */
export const DEFAULT_MINIMAX_TTS_VOICE = "female-shaonv";

export const MINIMAX_TTS_VOICES = [
  { id: "female-shaonv", name: "少女音色", scene: "中文女声" },
  { id: "female-yujie", name: "御姐音色", scene: "中文女声" },
  { id: "female-chengshu", name: "成熟女性音色", scene: "中文女声" },
  { id: "female-tianmei", name: "甜美女性音色", scene: "中文女声" },
  { id: "tianxin_xiaoling", name: "甜心小玲", scene: "中文女声" },
  { id: "male-qn-qingse", name: "青涩青年音色", scene: "中文男声" },
  { id: "male-qn-jingying", name: "精英青年音色", scene: "中文男声" },
  { id: "junlang_nanyou", name: "俊朗男友", scene: "中文男声" },
];

const BY_ID = new Map(MINIMAX_TTS_VOICES.map((row) => [row.id, row]));

export function isMinimaxTtsVoice(raw) {
  return BY_ID.has(String(raw || "").trim());
}

export function getMinimaxTtsVoices() {
  return MINIMAX_TTS_VOICES.map(({ id, name, scene }) => ({ id, name, scene }));
}
