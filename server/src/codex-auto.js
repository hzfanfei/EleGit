import { CodexClassifier } from "codex-smart-router/src/classifier.mjs";
import { listCodexModels } from "./codex-models.js";

// Prefer models measured in this account, but only select entries in its catalog.
const TIERS = {
  economy: ["gpt-6.1-terra", "gpt-6-luna", "gpt-6.1-sol"],
  balanced: ["gpt-6.1-terra", "gpt-6-luna", "gpt-6.1-sol"],
  complex: ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol"],
  frontier: ["gpt-6.1-sol", "gpt-6-sol", "gpt-6.1-terra"],
};

export async function selectAutoModel({ question, history = [], hasImages = false, codexPath, previous, getModels = listCodexModels, classifier } = {}) {
  const models = await getModels();
  const find = ids => ids.map(id => models.find(model => model.id === id)).find(Boolean);
  const fallback = find(TIERS.complex);
  if (!fallback) throw new Error("Auto 模式未找到可用的 Codex 模型，请手动选择模型");
  const classifierModel = find(["gpt-6-luna", "gpt-5.6-luna", "gpt-6.1-terra"]);
  let decision;
  try {
    if (!classifierModel && !classifier) throw new Error("分类模型不可用");
    const engine = classifier || new CodexClassifier({ codexPath, model: classifierModel.id, timeoutMs: 30000 });
    decision = await engine.classify({
      prompt: String(question || "").slice(0, 12000),
      history: history.filter(m => m?.role === "user" || m?.role === "assistant").slice(-6)
        .map(m => ({ role: m.role, content: String(m.content || "").slice(0, 2000) })),
      hasImages,
      previousRoute: previous ? { tier: previous.tier, model: previous.model, effort: previous.effort } : null,
    });
    if (!TIERS[decision.tier]) throw new Error("分类结果无效");
  } catch {
    return { model: fallback.id, effort: fallback.reasoningEfforts.includes("medium") ? "medium" : fallback.defaultReasoningEffort, tier: "complex", fallback: true };
  }
  const model = find(TIERS[decision.tier]) || fallback;
  const wanted = decision.tier === "frontier" ? "high" : decision.tier === "complex" ? "medium" : "low";
  return { model: model.id, effort: model.reasoningEfforts.includes(wanted) ? wanted : model.defaultReasoningEffort, tier: decision.tier, fallback: false };
}
