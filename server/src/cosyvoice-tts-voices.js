import {
  defaultCosyvoiceVoiceId,
  loadCosyvoiceVoiceCatalog,
} from "./load-cosyvoice-voices.js";

export const DEFAULT_COSYVOICE_TTS_VOICE = defaultCosyvoiceVoiceId();

export function getCosyvoiceTtsVoices() {
  return loadCosyvoiceVoiceCatalog().voices;
}

/** @deprecated use getCosyvoiceTtsVoices() */
export const COSYVOICE_TTS_VOICES = getCosyvoiceTtsVoices();

export function isCosyvoiceTtsVoice(id) {
  const voice = String(id || "").trim();
  return getCosyvoiceTtsVoices().some((row) => row.id === voice);
}
