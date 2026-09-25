/** MiMo TTS preset voices. ids stay ASCII so the phone can save them; apiVoice is what the API expects. */
export const DEFAULT_XIAOMI_TTS_VOICE = "bingtang";

export const XIAOMI_TTS_VOICES = [
  { id: "bingtang", name: "冰糖", scene: "中文女声", apiVoice: "冰糖" },
  { id: "moli", name: "茉莉", scene: "中文女声", apiVoice: "茉莉" },
  { id: "suda", name: "苏打", scene: "中文女声", apiVoice: "苏打" },
  { id: "baihua", name: "白桦", scene: "中文男声", apiVoice: "白桦" },
  { id: "mia", name: "Mia", scene: "英文女声", apiVoice: "Mia" },
  { id: "chloe", name: "Chloe", scene: "英文女声", apiVoice: "Chloe" },
  { id: "milo", name: "Milo", scene: "英文男声", apiVoice: "Milo" },
  { id: "dean", name: "Dean", scene: "英文男声", apiVoice: "Dean" },
  { id: "mimo_default", name: "默认", scene: "默认", apiVoice: "mimo_default" },
];

const BY_ID = new Map(XIAOMI_TTS_VOICES.map((row) => [row.id, row]));

export function isXiaomiTtsVoice(raw) {
  return BY_ID.has(String(raw || "").trim());
}

export function xiaomiApiVoice(raw) {
  return BY_ID.get(String(raw || "").trim())?.apiVoice || BY_ID.get(DEFAULT_XIAOMI_TTS_VOICE).apiVoice;
}

export function getXiaomiTtsVoices() {
  return XIAOMI_TTS_VOICES.map(({ id, name, scene }) => ({ id, name, scene }));
}
