import { test } from "node:test";
import assert from "node:assert/strict";
import { selectAutoModel } from "../src/codex-auto.js";

const models = [
  { id: "gpt-6.1-terra", reasoningEfforts: ["low", "medium"], defaultReasoningEffort: "low" },
  { id: "gpt-6.1-sol", reasoningEfforts: ["low", "medium", "high"], defaultReasoningEffort: "medium" },
];
const getModels = async () => models;

test("Auto routes with conversation context and supported effort", async () => {
  let input;
  const classifier = { classify: async value => { input = value; return { tier: "frontier" }; } };
  const route = await selectAutoModel({ question: "继续", history: [{ role: "user", content: "分析架构" }], getModels, classifier });
  assert.equal(input.history[0].content, "分析架构");
  assert.deepEqual(route, { model: "gpt-6.1-sol", effort: "high", tier: "frontier", fallback: false });
});

test("Auto falls back to a capable model when classification fails", async () => {
  const classifier = { classify: async () => { throw new Error("timeout"); } };
  const route = await selectAutoModel({ question: "test", getModels, classifier });
  assert.deepEqual(route, { model: "gpt-6.1-sol", effort: "medium", tier: "complex", fallback: true });
});
