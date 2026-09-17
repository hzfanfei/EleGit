/** User-facing STT error hints (Chinese). Never expose env var names. */

export function sttErrorFromFailure(err, frameMessage = "") {
  const parts = [String(err?.message || err || ""), String(frameMessage || "")].join(" ");
  const lower = parts.toLowerCase();

  if (lower.includes("timeout") || lower.includes("timed out") || lower.includes("etimedout")) {
    return { code: "network", hint: "语音识别响应超时。请检查网络后重试。" };
  }
  if (
    lower.includes("econnrefused") ||
    lower.includes("connection refused") ||
    lower.includes("enotfound") ||
    lower.includes("network") ||
    lower.includes("socket hang up")
  ) {
    return { code: "network", hint: "连不上语音识别服务。请检查网络后重试。" };
  }
  if (
    lower.includes("401") ||
    lower.includes("403") ||
    lower.includes("unauthorized") ||
    lower.includes("invalid token") ||
    lower.includes("access denied") ||
    lower.includes("authentication")
  ) {
    return {
      code: "asr_auth",
      hint: "语音密钥无效或已过期。请检查本机 .env 里的语音配置。",
    };
  }
  if (
    lower.includes("resource") ||
    lower.includes("quota") ||
    lower.includes("not granted") ||
    lower.includes("no permission") ||
    lower.includes("x-api-resource")
  ) {
    return {
      code: "asr_resource",
      hint: "语音识别资源未开通或资源 ID 不对。请看配置说明里的火山 ASR 步骤。",
    };
  }
  return { code: "asr_failed", hint: "语音识别暂时不可用。请稍后重试。" };
}

export function sttErrorFromVolcFrame(frame) {
  if (!frame || frame.type !== "error") return null;
  return sttErrorFromFailure(null, frame.message || String(frame.code || ""));
}
