import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { mermaidCacheId, renderMermaidSvg } from "../src/mermaid-render.js";

describe("mermaid-render", () => {
  it("mermaidCacheId is stable", () => {
    const a = mermaidCacheId("graph TD\n  A-->B", "dark", "transparent");
    const b = mermaidCacheId("graph TD\n  A-->B", "dark", "transparent");
    assert.equal(a, b);
    assert.notEqual(a, mermaidCacheId("graph TD\n  A-->B", "default", "transparent"));
  });

  it("renders a simple flowchart to SVG", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "wx-mmd-test-"));
    const { svg, id, cached } = await renderMermaidSvg({
      code: "flowchart LR\n  A[开始] --> B[结束]",
      theme: "dark",
      backgroundColor: "transparent",
      workspaceRoot,
    });
    assert.match(svg, /<svg[\s>]/i);
    assert.ok(id.length >= 16);
    assert.equal(cached, false);

    const again = await renderMermaidSvg({
      code: "flowchart LR\n  A[开始] --> B[结束]",
      theme: "dark",
      backgroundColor: "transparent",
      workspaceRoot,
    });
    assert.equal(again.cached, true);
    assert.equal(again.id, id);
  });
});
