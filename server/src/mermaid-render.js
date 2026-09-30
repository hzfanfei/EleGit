import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const here = dirname(fileURLToPath(import.meta.url));
const MMDC = join(here, "..", "node_modules", "@mermaid-js", "mermaid-cli", "src", "cli.js");

const MAX_CODE_LEN = 48_000;
const RENDER_TIMEOUT_MS = 28_000;

export function mermaidCacheDir(workspaceRoot) {
  return join(String(workspaceRoot || "."), ".wenxiang", "mermaid-cache");
}

export function mermaidCacheId(code, theme, backgroundColor) {
  const payload = JSON.stringify({
    code: String(code || "").trim(),
    theme: theme || "default",
    backgroundColor: backgroundColor || "transparent",
  });
  return createHash("sha256").update(payload).digest("hex").slice(0, 32);
}

export async function readCachedMermaidSvg(workspaceRoot, id) {
  const path = join(mermaidCacheDir(workspaceRoot), `${id}.svg`);
  await access(path, constants.R_OK);
  return readFile(path, "utf8");
}

/**
 * Render Mermaid source to SVG via @mermaid-js/mermaid-cli (full syntax).
 */
export async function renderMermaidSvg({
  code,
  theme = "default",
  backgroundColor = "transparent",
  workspaceRoot,
  useCache = true,
}) {
  const trimmed = String(code || "").trim();
  if (!trimmed) {
    const err = new Error("Mermaid 源码为空");
    err.code = "mermaid_empty";
    throw err;
  }
  if (trimmed.length > MAX_CODE_LEN) {
    const err = new Error("Mermaid 源码过长");
    err.code = "mermaid_too_long";
    throw err;
  }

  const safeTheme = theme === "dark" ? "dark" : "default";
  const id = mermaidCacheId(trimmed, safeTheme, backgroundColor);
  const cachePath = join(mermaidCacheDir(workspaceRoot), `${id}.svg`);

  if (useCache) {
    try {
      const svg = await readCachedMermaidSvg(workspaceRoot, id);
      return { id, svg, cached: true };
    } catch {
      // miss
    }
  }

  const work = await mkdtemp(join(tmpdir(), "wx-mmd-"));
  try {
    const input = join(work, "diagram.mmd");
    const output = join(work, "diagram.svg");
    await writeFile(input, trimmed, "utf8");
    await execFileAsync(
      process.execPath,
      [MMDC, "-i", input, "-o", output, "-t", safeTheme, "-b", backgroundColor, "-q"],
      { timeout: RENDER_TIMEOUT_MS, windowsHide: true },
    );
    const svg = await readFile(output, "utf8");
    if (!svg.trim()) {
      const err = new Error("Mermaid 渲染结果为空");
      err.code = "mermaid_empty_svg";
      throw err;
    }
    if (useCache && workspaceRoot) {
      await mkdir(mermaidCacheDir(workspaceRoot), { recursive: true });
      await writeFile(cachePath, svg, "utf8");
    }
    return { id, svg, cached: false };
  } finally {
    await rm(work, { recursive: true, force: true });
  }
}
