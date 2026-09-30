import { createHash } from "node:crypto";
import { constants, existsSync } from "node:fs";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import puppeteer from "puppeteer";

const here = dirname(fileURLToPath(import.meta.url));
const MMDC = join(here, "..", "node_modules", "@mermaid-js", "mermaid-cli", "src", "cli.js");

function mermaidAssetPaths() {
  const cliEntry = fileURLToPath(import.meta.resolve("@mermaid-js/mermaid-cli"));
  const mermaidPkg = fileURLToPath(import.meta.resolve("mermaid/package.json"));
  return {
    html: join(dirname(cliEntry), "..", "dist", "index.html"),
    js: join(dirname(mermaidPkg), "dist", "mermaid.js"),
  };
}

const MAX_CODE_LEN = 48_000;
const RENDER_TIMEOUT_MS = 28_000;
/** Lossy WebP. Phone Image.memory decodes it; much smaller than the old PNG. */
const WEBP_QUALITY = 80;

export function mermaidCliPath() {
  return MMDC;
}

export function mermaidCliInstalledSync() {
  return existsSync(MMDC);
}

/** User-facing message from mmdc / Puppeteer failures. */
export function formatMermaidCliError(err) {
  const stderr = String(err?.stderr || "");
  const stdout = String(err?.stdout || "");
  const message = String(err?.message || err || "");
  const combined = `${stderr}\n${stdout}\n${message}`;

  const parse = combined.match(/Parse error on line[^\n]+(?:\n[^\n]+){0,2}/i);
  if (parse) return parse[0].trim();

  if (/ENOENT/i.test(combined) && /mermaid-cli|cli\.js/i.test(combined)) {
    return "Mermaid CLI 未安装，请在 server 目录执行 npm install";
  }
  if (err?.killed || /ETIMEDOUT|timed out|timeout/i.test(combined)) {
    return "Mermaid 渲染超时，请简化图表后重试";
  }

  for (const line of combined.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("Error:")) {
      return trimmed.replace(/^Error:\s*/i, "").trim();
    }
  }

  const clipped = combined.replace(/\s+/g, " ").trim();
  if (clipped.length > 480) return `${clipped.slice(0, 480)}…`;
  return clipped || "Mermaid 渲染失败";
}

export function mermaidCacheDir(workspaceRoot) {
  return join(String(workspaceRoot || "."), ".wenxiang", "mermaid-cache");
}

/** Paper card. Dark/transparent requests from the app still paint as light ink. */
export function resolveMermaidPaint(theme, backgroundColor) {
  const bg = String(backgroundColor || "").trim();
  const transparent = bg === "" || /^transparent$/i.test(bg) || /^none$/i.test(bg);
  if (transparent || theme === "dark") {
    return { theme: "default", backgroundColor: "#F4F0E8" };
  }
  const safeTheme = theme === "forest" || theme === "neutral" ? theme : "default";
  return { theme: safeTheme, backgroundColor: bg };
}

export function mermaidCacheId(code, theme, backgroundColor) {
  const paint = resolveMermaidPaint(theme, backgroundColor);
  const payload = JSON.stringify({
    code: String(code || "").trim(),
    theme: paint.theme,
    backgroundColor: paint.backgroundColor,
    render: "flutter-webp-1",
  });
  return createHash("sha256").update(payload).digest("hex").slice(0, 32);
}

export async function readCachedMermaidSvg(workspaceRoot, id) {
  const path = join(mermaidCacheDir(workspaceRoot), `${id}.svg`);
  await access(path, constants.R_OK);
  return readFile(path, "utf8");
}

function cachePaths(workspaceRoot, id) {
  const dir = mermaidCacheDir(workspaceRoot);
  return { dir, svg: join(dir, `${id}.svg`), webp: join(dir, `${id}.webp`) };
}

async function readCachedDiagram(workspaceRoot, id) {
  const paths = cachePaths(workspaceRoot, id);
  const [svg, webp] = await Promise.all([
    readFile(paths.svg, "utf8"),
    readFile(paths.webp),
  ]);
  return { svg, webp };
}

/**
 * Chrome paints the diagram (arrows, CJK). The SVG copy inlines colors and
 * uses the app's WenxiangSerif face so flutter_svg on already-installed builds
 * can draw it. flutter_svg ignores `<style>` and `<foreignObject>`.
 */
async function renderWithPuppeteer(code, paint, assets) {
  const browser = await puppeteer.launch({
    headless: "shell",
    args: ["--no-sandbox", "--disable-dev-shm-usage", "--font-render-hinting=none"],
  });
  const logs = [];
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(RENDER_TIMEOUT_MS);
    page.setDefaultNavigationTimeout(RENDER_TIMEOUT_MS);
    page.on("console", (msg) => {
      if (msg.type() === "error") logs.push(msg.text());
    });
    page.on("pageerror", (err) => logs.push(String(err)));
    await page.setViewport({ width: 1400, height: 900, deviceScaleFactor: 2 });
    await page.goto(pathToFileURL(assets.html).href);
    await page.$eval(
      "body",
      (body, backgroundColor) => {
        body.style.background = backgroundColor;
      },
      paint.backgroundColor,
    );
    await page.addScriptTag({ path: assets.js });
    const mermaidConfig = {
      startOnLoad: false,
      theme: paint.theme,
      fontFamily: '"Microsoft YaHei", "Segoe UI", sans-serif',
      htmlLabels: false,
      flowchart: { htmlLabels: false, useMaxWidth: true },
      sequence: {
        useMaxWidth: true,
        actorFontFamily: '"Microsoft YaHei", sans-serif',
        noteFontFamily: '"Microsoft YaHei", sans-serif',
        messageFontFamily: '"Microsoft YaHei", sans-serif',
      },
    };
    try {
      await page.$eval(
        "#container",
        async (container, definition, mermaidConfig, backgroundColor) => {
          const { mermaid, zenuml, elkLayouts } = globalThis;
          if (zenuml && mermaid.registerExternalDiagrams) {
            await mermaid.registerExternalDiagrams([zenuml]);
          }
          if (elkLayouts && mermaid.registerLayoutLoaders) {
            mermaid.registerLayoutLoaders(elkLayouts);
          }
          mermaid.initialize(mermaidConfig);
          const { svg: svgText } = await mermaid.render("my-svg", definition, container);
          container.innerHTML = svgText;
          const svg = container.querySelector("svg");
          if (svg?.style) svg.style.backgroundColor = backgroundColor;
        },
        code,
        mermaidConfig,
        paint.backgroundColor,
      );
    } catch (renderErr) {
      const err = new Error(formatMermaidCliError({
        message: String(renderErr?.message || renderErr),
        stderr: logs.join("\n"),
      }));
      err.code = "mermaid_render_failed";
      throw err;
    }

    const clip = await page.$eval("svg", (svg) => {
      const rect = svg.getBoundingClientRect();
      return {
        x: Math.max(0, Math.floor(rect.left)),
        y: Math.max(0, Math.floor(rect.top)),
        width: Math.ceil(rect.width),
        height: Math.ceil(rect.height),
      };
    });
    if (clip.width < 2 || clip.height < 2) {
      const err = new Error("Mermaid 渲染结果为空");
      err.code = "mermaid_empty_svg";
      throw err;
    }
    await page.setViewport({
      width: Math.max(1, clip.x + clip.width),
      height: Math.max(1, clip.y + clip.height),
      deviceScaleFactor: 2,
    });
    const webp = Buffer.from(
      await page.screenshot({ clip, type: "webp", quality: WEBP_QUALITY, omitBackground: false }),
    );

    const svg = await page.$eval("svg", (svg) => {
      const shapes = new Set(["path", "rect", "circle", "ellipse", "polygon", "polyline", "line", "text", "tspan"]);
      const cssColorToHex = (value) => {
        if (!value || value === "none") return "none";
        const match = String(value).match(
          /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)$/i,
        );
        if (!match) return value;
        const alpha = match[4] === undefined ? 1 : Number(match[4]);
        if (alpha === 0) return "none";
        const hex = (n) => Math.max(0, Math.min(255, Math.round(Number(n)))).toString(16).padStart(2, "0");
        return `#${hex(match[1])}${hex(match[2])}${hex(match[3])}`;
      };
      for (const el of svg.querySelectorAll("*")) {
        const tag = el.tagName.toLowerCase();
        if (!shapes.has(tag)) continue;
        const cs = getComputedStyle(el);
        const fill = cssColorToHex(cs.fill);
        const stroke = cssColorToHex(cs.stroke);
        if (fill) el.setAttribute("fill", fill);
        if (stroke) el.setAttribute("stroke", stroke);
        if (cs.strokeWidth) el.setAttribute("stroke-width", cs.strokeWidth);
        if (cs.fontSize) el.setAttribute("font-size", cs.fontSize);
        el.removeAttribute("style");
        el.removeAttribute("filter");
        if (tag === "text" || tag === "tspan") {
          el.setAttribute("font-family", "WenxiangSerif");
          const weight = cs.fontWeight;
          if (/^\d+$/.test(weight) || weight === "normal" || weight === "bold") {
            el.setAttribute("font-weight", weight);
          }
        }
      }
      for (const el of svg.querySelectorAll("text")) {
        const baseline = (el.getAttribute("dominant-baseline") || "").toLowerCase();
        if (baseline !== "central" && baseline !== "middle") continue;
        const fontSize = parseFloat(getComputedStyle(el).fontSize) || 16;
        const shift = -(fontSize * 0.35);
        const tspans = [...el.querySelectorAll("tspan")];
        if (tspans.length) {
          for (const tspan of tspans) {
            const dy = parseFloat(tspan.getAttribute("dy") || "0") || 0;
            tspan.setAttribute("dy", String(Math.round((dy + shift) * 100) / 100));
          }
        } else {
          el.setAttribute("dy", String(Math.round(shift * 100) / 100));
        }
        el.setAttribute("dominant-baseline", "auto");
      }
      svg.querySelectorAll("style, script, foreignObject").forEach((node) => node.remove());
      const box = svg.viewBox?.baseVal;
      if (box?.width) {
        svg.setAttribute("width", String(box.width));
        svg.setAttribute("height", String(box.height));
      }
      svg.removeAttribute("style");
      return new XMLSerializer().serializeToString(svg);
    });
    if (!svg.trim() || webp.length < 12) {
      const err = new Error("Mermaid 渲染结果为空");
      err.code = "mermaid_empty_svg";
      throw err;
    }
    return { svg, webp };
  } finally {
    await browser.close();
  }
}

/**
 * Render Mermaid to a WebP (phone) and a flutter_svg-safe SVG (installed builds).
 * The JSON field stays `png` so builds that already decode the raster keep working.
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

  const paint = resolveMermaidPaint(theme, backgroundColor);
  const id = mermaidCacheId(trimmed, theme, backgroundColor);
  const paths = cachePaths(workspaceRoot, id);

  if (useCache) {
    try {
      const cached = await readCachedDiagram(workspaceRoot, id);
      return { id, svg: cached.svg, webp: cached.webp, cached: true };
    } catch {
      // miss
    }
  }

  let assets;
  try {
    assets = mermaidAssetPaths();
  } catch {
    assets = null;
  }
  if (!mermaidCliInstalledSync() || !assets || !existsSync(assets.html) || !existsSync(assets.js)) {
    const err = new Error("Mermaid CLI 未安装，请在 server 目录执行 npm install");
    err.code = "mermaid_cli_missing";
    throw err;
  }

  const { svg, webp } = await renderWithPuppeteer(trimmed, paint, assets);
  if (useCache && workspaceRoot) {
    await mkdir(paths.dir, { recursive: true });
    await Promise.all([
      writeFile(paths.svg, svg, "utf8"),
      writeFile(paths.webp, webp),
    ]);
  }
  return { id, svg, webp, cached: false };
}
