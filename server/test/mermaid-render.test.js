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
    assert.notEqual(a, mermaidCacheId("graph TD\n  A-->B", "default", "#FAF8F5"));
  });

  it("renders a flowchart to PNG and a flutter-safe SVG", async () => {
    const workspaceRoot = await mkdtemp(join(tmpdir(), "wx-mmd-test-"));
    const { svg, png, id, cached } = await renderMermaidSvg({
      code: "flowchart LR\n  A[开始] --> B[结束]",
      theme: "dark",
      backgroundColor: "transparent",
      workspaceRoot,
    });
    assert.match(svg, /<svg[\s>]/i);
    assert.match(svg, /开始/);
    assert.doesNotMatch(svg, /foreignObject/i);
    assert.doesNotMatch(svg, /<style[\s>]/i);
    assert.match(svg, /font-family="WenxiangSerif"/);
    assert.equal(png[0], 0x89);
    assert.equal(png[1], 0x50);
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
