import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  formatMermaidCliError,
  mermaidCacheId,
  renderMermaidSvg,
} from "../src/mermaid-render.js";

describe("mermaid-render", () => {
  it("formatMermaidCliError surfaces parse errors", () => {
    const msg = formatMermaidCliError({
      message: "Command failed",
      stderr: "Error: Parse error on line 2:\n...",
    });
    assert.match(msg, /Parse error on line/i);
  });

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

  it("rejects invalid diagram with a short message", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "wx-mmd-bad-"));
    await assert.rejects(
      () =>
        renderMermaidSvg({
          code: "flowchart LR\n  BAD-->",
          theme: "dark",
          workspaceRoot,
          useCache: false,
        }),
      (err) => {
        assert.equal(err.code, "mermaid_render_failed");
        assert.match(err.message, /Parse error on line/i);
        return true;
      },
    );
  });
});
