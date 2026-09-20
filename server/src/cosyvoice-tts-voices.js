/** Local Fun-CosyVoice3 speakers (companion preloads zero-shot cache at startup). */
export const DEFAULT_COSYVOICE_TTS_VOICE = "wenxiang_default";

export const COSYVOICE_TTS_VOICES = [
  {
    id: "wenxiang_default",
    name: "问象默认",
    scene: "Fun-CosyVoice3 · 本地",
  },
];

export function isCosyvoiceTtsVoice(id) {
  const voice = String(id || "").trim();
  return COSYVOICE_TTS_VOICES.some((row) => row.id === voice);
}
