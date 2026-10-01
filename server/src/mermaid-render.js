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

const ER_TYPE_NAMES = [
  "integer",
  "int",
  "datetime",
  "date",
  "boolean",
  "bool",
  "double",
  "float",
  "varchar",
  "string",
  "number",
  "char",
];
const ER_TYPE_ALT = ER_TYPE_NAMES.join("|");

function maskMatches(source, pattern) {
  const kept = [];
  const masked = source.replace(pattern, (match) => {
    const token = `\uE000${kept.length}\uE001`;
    kept.push(match);
    return token;
  });
  return { masked, kept };
}

function unmask(source, kept) {
  if (!kept.length) return source;
  return source.replace(/\uE000(\d+)\uE001/g, (_, index) => kept[Number(index)]);
}

/** `integername` / `string文本` → separate the type. Leave `integer` itself intact. */
function glueErTypes(source) {
  const types = [...ER_TYPE_NAMES].sort((a, b) => b.length - a.length);
  return source.replace(/[A-Za-z]+/g, (word, offset, whole) => {
    const next = whole[offset + word.length] || "";
    const lower = word.toLowerCase();
    for (const type of types) {
      if (lower === type) return next && !/\s/.test(next) ? `${word} ` : word;
      if (!lower.startsWith(type)) continue;
      const rest = word.slice(type.length);
      if (/^[a-z]/.test(rest)) return `${word.slice(0, type.length)} ${rest}`;
      return word;
    }
    return word;
  });
}

function glueTypesInBlocks(source) {
  return source.replace(/(?<![o|])\{([^{}]*)\}/g, (_full, inner) => `{${glueErTypes(inner)}}`);
}

/** Put class, ER, and pie statements back on their own lines. */
export function normalizeMermaidSource(code) {
  const text = String(code || "").replace(/\r\n/g, "\n").replace(/\r/g, "\n").trim();
  if (!text) return text;
  const flat = text.replace(/\s+/g, " ").trim();
  const lower = flat.toLowerCase();
  if (lower.startsWith("classdiagram")) {
    const v2 = lower.startsWith("classdiagram-v2");
    const header = v2 ? "classDiagram-v2" : "classDiagram";
    const body = splitClassBody(flat.slice(header.length).trim());
    return body ? `${header}\n${body}` : header;
  }
  if (lower.startsWith("erdiagram")) {
    const body = splitErBody(flat.slice("erdiagram".length).trim());
    return body ? `erDiagram\n${body}` : "erDiagram";
  }
  if (lower.startsWith("pie")) {
    let body = flat.slice(3).trim();
    let header = "pie";
    if (/^showdata/i.test(body)) {
      header = "pie showData";
      body = body.replace(/^showdata/i, "").trim();
    }
    const lines = splitPieBody(body);
    return lines ? `${header}\n${lines}` : header;
  }
  return text;
}

function applyCuts(source, cuts) {
  const unique = [...new Set(cuts.filter((cut) => cut > 0 && cut < source.length && source[cut - 1] !== "\n"))];
  unique.sort((a, b) => b - a);
  let out = source;
  for (const cut of unique) {
    const left = out.slice(0, cut).replace(/[ \t]+$/g, "");
    out = `${left}\n${out.slice(cut)}`;
  }
  return out;
}

function peelLabeledName(source, index, name, entityUpper) {
  const peeled = entityUpper
    ? name.match(/^(.*[a-z])([A-Z][A-Z0-9_-]*)$/)
    : name.match(/^(.*[a-z])([A-Z][A-Za-z0-9_]*)$/);
  if (!peeled || !/:\s*$/.test(source.slice(0, index))) return index;
  return index + peeled[1].length;
}

function classRelationCuts(source) {
  const re =
    /([A-Za-z_][A-Za-z0-9_]*)(?:\s*(?:"[^"]*"|'[^']*'|\d+|\*))?\s*(?:<\|--|<\|\.\.|\*--|o--|-->|<--|==>|\.\.>|\.\.|--)/g;
  const cuts = [];
  for (const match of source.matchAll(re)) {
    cuts.push(peelLabeledName(source, match.index, match[1], false));
  }
  return cuts;
}

function erRelationCuts(source) {
  const re = /([A-Za-z_](?:[A-Za-z0-9_]|-(?=[A-Za-z0-9_]))*)\s*(?:\|\||\|o|\}o|\}\|)(?:--|\.\.)/g;
  const cuts = [];
  for (const match of source.matchAll(re)) {
    cuts.push(peelLabeledName(source, match.index, match[1], true));
  }
  return cuts;
}

function erBlockCuts(source) {
  const cuts = [];
  for (const match of source.matchAll(/(?<![o|])\{/g)) {
    let index = match.index - 1;
    while (index >= 0 && /\s/.test(source[index])) index -= 1;
    const end = index + 1;
    while (index >= 0) {
      const ch = source[index];
      if (/[A-Za-z0-9_]/.test(ch)) {
        index -= 1;
        continue;
      }
      if (
        ch === "-" &&
        /[A-Za-z0-9_]/.test(source[index - 1] || "") &&
        /[A-Za-z0-9_]/.test(source[index + 1] || "")
      ) {
        index -= 1;
        continue;
      }
      break;
    }
    const start = index + 1;
    if (start >= end) continue;
    const name = source.slice(start, end);
    const peeled = name.match(/^(.*[a-z])([A-Z][A-Z0-9_-]*)$/);
    let cut = start;
    if (peeled && /:\s*$/.test(source.slice(0, start))) cut = start + peeled[1].length;
    cuts.push(cut);
  }
  return cuts;
}

/** Put a relationship arrow back together when a line break landed inside it. */
function repairSplitClassArrows(source) {
  return String(source)
    .replace(/<\|\s*-\s+-/g, "<|--")
    .replace(/<\|\s*\.\s+\./g, "<|..")
    .replace(/\*\s*-\s+-/g, "*--")
    .replace(/(?<![A-Za-z0-9_])o\s*-\s+-/g, "o--")
    .replace(/(?<![|])<\s*-\s+-/g, "<--");
}

function splitClassBody(body) {
  let s = String(body || "").trim();
  if (!s) return s;
  s = repairSplitClassArrows(s);
  s = s.replace(/(?<=\})(?=[A-Za-z_][A-Za-z0-9_])/g, "\n");
  s = s.replace(
    /(?:\s+|(?<=\S))(?=(?:classDef|cssClass|namespace|direction)\b|note\s+(?:for\b|"))/g,
    "\n",
  );
  s = s.replace(/\s+(?=class(?!Def\b|Diagram\b)\b)/g, "\n");
  s = s.replace(/(?<=\S)(?=class(?!Def\b|Diagram\b)\b)/g, "\n");
  s = s.replace(/\bclass(?!Def\b|Diagram\b)(?=\S)/g, "class ");
  s = s.replace(/\{(?!\n)/g, "{\n");
  s = s.replace(/\s*(?=})/g, "\n");
  const generics = maskMatches(s, /~[^~\s{}]+~/g);
  s = generics.masked;
  // A private member starts with "-", but the second dash of <|--, *--, o--
  // is not one: it is preceded by another relationship character.
  // "#" after ":" is a color, not protected visibility.
  s = s.replace(/(?:(?<=\S)\s*|\s+)(?=(?:[+~]|(?<!:)#|(?<![-|<*o.])-(?![->.])))/g, "\n");
  s = applyCuts(s, classRelationCuts(s));
  s = unmask(s, generics.kept);
  return s.replace(/\n{2,}/g, "\n").trim();
}

function splitErBody(body) {
  let s = String(body || "").trim();
  if (!s) return s;
  const quoted = maskMatches(s, /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g);
  s = glueTypesInBlocks(quoted.masked);
  s = applyCuts(s, erRelationCuts(s));
  s = applyCuts(s, erBlockCuts(s));
  s = s.replace(/(?<![o|])\{(?!\n)/g, "{\n");
  s = s.replace(/\s*\}(?!\s*[|o])/g, "\n}");
  s = s.replace(/(?<=\})(?=[A-Za-z_][A-Za-z0-9_])/g, "\n");
  s = s.replace(new RegExp(`\\s+(?=(?:${ER_TYPE_ALT})\\b)`, "gi"), "\n");
  s = unmask(s, quoted.kept);
  return s.replace(/\n{2,}/g, "\n").trim();
}

function splitPieBody(body) {
  let s = String(body || "").trim();
  if (!s) return s;
  s = s.replace(/(?:\s+|(?<=\S))(?=(?:"[^"\n]*"|'[^'\n]*')\s*:)/g, "\n");
  const quoted = maskMatches(s, /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g);
  s = quoted.masked;
  s = s.replace(/\btitle(?=[^\s:])/gi, "title ");
  s = s.replace(/\s+(?=title\b)/gi, "\n");
  s = unmask(s, quoted.kept);
  return s.replace(/\n{2,}/g, "\n").trim();
}

const MAX_CODE_LEN = 48_000;
const RENDER_TIMEOUT_MS = 28_000;

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

/** Warm paper. Matches the chat card; not Mermaid's default purple. */
const DIAGRAM_PAPER = "#F7F3EC";
const DIAGRAM_INK = "#2C2620";
const DIAGRAM_NODE = "#FBF7F1";
const DIAGRAM_NODE_LINE = "#C6A07A";
const DIAGRAM_CHOICE = "#F4E4D0";
const DIAGRAM_CHOICE_LINE = "#A67C52";
const DIAGRAM_ARROW = "#8A7056";

/** Paper card. Dark/transparent requests from the app still paint as light ink. */
export function resolveMermaidPaint(theme, backgroundColor) {
  const bg = String(backgroundColor || "").trim();
  const transparent = bg === "" || /^transparent$/i.test(bg) || /^none$/i.test(bg);
  if (transparent || theme === "dark") {
    return { theme: "base", backgroundColor: DIAGRAM_PAPER };
  }
  const safeTheme = theme === "forest" || theme === "neutral" ? theme : "base";
  return { theme: safeTheme, backgroundColor: bg || DIAGRAM_PAPER };
}

export function mermaidCacheId(code, theme, backgroundColor) {
  const paint = resolveMermaidPaint(theme, backgroundColor);
  const payload = JSON.stringify({
    code: String(code || "").trim(),
    theme: paint.theme,
    backgroundColor: paint.backgroundColor,
    render: "wenxiang-paper-2",
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
  return { dir, svg: join(dir, `${id}.svg`), png: join(dir, `${id}.png`) };
}

function isMermaidErrorSvg(svg) {
  const text = String(svg || "");
  return /aria-roledescription="error"/i.test(text) || /syntax error in text/i.test(text);
}

async function readCachedDiagram(workspaceRoot, id) {
  const paths = cachePaths(workspaceRoot, id);
  const [svg, png] = await Promise.all([
    readFile(paths.svg, "utf8"),
    readFile(paths.png),
  ]);
  if (isMermaidErrorSvg(svg)) {
    const err = new Error("cached mermaid error diagram");
    err.code = "mermaid_error_cache";
    throw err;
  }
  return { svg, png };
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
        body.style.margin = "0";
        body.style.padding = "12px";
        body.style.background = backgroundColor;
      },
      paint.backgroundColor,
    );
    await page.addScriptTag({ path: assets.js });
    const mermaidConfig = {
      startOnLoad: false,
      suppressErrorRendering: true,
      theme: "base",
      fontFamily: '"Microsoft YaHei", "Segoe UI", sans-serif',
      htmlLabels: false,
      themeVariables: {
        darkMode: false,
        background: paint.backgroundColor,
        fontFamily: '"Microsoft YaHei", "Segoe UI", sans-serif',
        fontSize: "16px",
        primaryColor: DIAGRAM_NODE,
        primaryTextColor: DIAGRAM_INK,
        primaryBorderColor: DIAGRAM_NODE_LINE,
        secondaryColor: DIAGRAM_CHOICE,
        secondaryTextColor: DIAGRAM_INK,
        secondaryBorderColor: DIAGRAM_CHOICE_LINE,
        tertiaryColor: DIAGRAM_CHOICE,
        tertiaryTextColor: DIAGRAM_INK,
        tertiaryBorderColor: DIAGRAM_NODE_LINE,
        lineColor: DIAGRAM_ARROW,
        textColor: DIAGRAM_INK,
        mainBkg: DIAGRAM_NODE,
        nodeBorder: DIAGRAM_NODE_LINE,
        clusterBkg: DIAGRAM_CHOICE,
        clusterBorder: DIAGRAM_NODE_LINE,
        defaultLinkColor: DIAGRAM_ARROW,
        titleColor: DIAGRAM_INK,
        pie1: "#C47B4A",
        pie2: "#6E8B74",
        pie3: "#A65D57",
        pie4: "#7D8AA6",
        pie5: "#C4A35A",
        pie6: "#8A7056",
        pie7: "#9A7A62",
        pie8: "#8E9A84",
        pie9: "#B76E79",
        pie10: "#6F8F9A",
        pie11: "#D4A574",
        pie12: "#7A6A58",
        pieOpacity: "1",
        pieStrokeColor: DIAGRAM_INK,
        pieStrokeWidth: "1px",
        pieOuterStrokeColor: DIAGRAM_INK,
        pieTitleTextColor: DIAGRAM_INK,
        pieSectionTextColor: DIAGRAM_INK,
        pieLegendTextColor: DIAGRAM_INK,
        edgeLabelBackground: paint.backgroundColor,
        nodeTextColor: DIAGRAM_INK,
        actorBkg: DIAGRAM_NODE,
        actorBorder: DIAGRAM_NODE_LINE,
        actorTextColor: DIAGRAM_INK,
        signalColor: DIAGRAM_ARROW,
        signalTextColor: DIAGRAM_INK,
        labelBoxBkgColor: DIAGRAM_NODE,
        labelBoxBorderColor: DIAGRAM_NODE_LINE,
        labelTextColor: DIAGRAM_INK,
        noteBkgColor: DIAGRAM_CHOICE,
        noteTextColor: DIAGRAM_INK,
        noteBorderColor: DIAGRAM_NODE_LINE,
      },
      flowchart: {
        htmlLabels: false,
        useMaxWidth: false,
        curve: "basis",
        padding: 12,
        nodeSpacing: 22,
        rankSpacing: 26,
        diagramPadding: 8,
      },
      sequence: {
        useMaxWidth: false,
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
          const paintShape = (el, fill, stroke) => {
            el.style.fill = fill;
            el.style.stroke = stroke;
            el.style.strokeWidth = "1.5px";
          };
          svg?.querySelectorAll(".node rect").forEach((el) => {
            paintShape(el, "#FBF7F1", "#C6A07A");
            el.setAttribute("rx", "14");
            el.setAttribute("ry", "14");
          });
          svg?.querySelectorAll(".node polygon").forEach((el) => {
            paintShape(el, "#F4E4D0", "#A67C52");
          });
          svg?.querySelectorAll(".node circle, .node ellipse").forEach((el) => {
            paintShape(el, "#FBF7F1", "#C6A07A");
          });
          svg?.querySelectorAll(".edgePath path, .flowchart-link").forEach((el) => {
            el.style.stroke = "#8A7056";
            el.style.strokeWidth = "1.6px";
          });
          svg?.querySelectorAll("marker path, marker polygon").forEach((el) => {
            el.style.fill = "#8A7056";
            el.style.stroke = "#8A7056";
          });
          svg?.querySelectorAll(".edgeLabel rect, .labelBkg").forEach((el) => {
            el.style.fill = backgroundColor;
            el.style.stroke = "none";
          });
          svg?.querySelectorAll(".node text, .edgeLabel text, .edgeLabel tspan").forEach((el) => {
            el.style.fill = "#2C2620";
          });
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
    const png = Buffer.from(
      await page.screenshot({ clip, type: "png", omitBackground: false }),
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
    if (!svg.trim() || png.length < 8) {
      const err = new Error("Mermaid 渲染结果为空");
      err.code = "mermaid_empty_svg";
      throw err;
    }
    if (isMermaidErrorSvg(svg)) {
      const err = new Error("Mermaid 语法错误");
      err.code = "mermaid_render_failed";
      throw err;
    }
    return { svg, png };
  } finally {
    await browser.close();
  }
}

/** Parse many diagrams in one browser. A syntax error is a failed probe. */
export async function probeMermaidSources(codes) {
  const list = Array.isArray(codes) ? codes : [];
  const assets = mermaidAssetPaths();
  if (!mermaidCliInstalledSync() || !existsSync(assets.html) || !existsSync(assets.js)) {
    const err = new Error("Mermaid CLI 未安装，请在 server 目录执行 npm install");
    err.code = "mermaid_cli_missing";
    throw err;
  }
  const browser = await puppeteer.launch({
    headless: "shell",
    args: ["--no-sandbox", "--disable-dev-shm-usage", "--font-render-hinting=none"],
  });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(RENDER_TIMEOUT_MS);
    await page.goto(pathToFileURL(assets.html).href);
    await page.addScriptTag({ path: assets.js });
    await page.evaluate(() => {
      globalThis.mermaid.initialize({
        startOnLoad: false,
        suppressErrorRendering: true,
        htmlLabels: false,
        fontFamily: '"Microsoft YaHei", "Segoe UI", sans-serif',
      });
    });
    const results = [];
    for (let i = 0; i < list.length; i += 1) {
      const source = normalizeMermaidSource(list[i]);
      const outcome = await page.evaluate(async (definition, elementId) => {
        const host = document.querySelector("#container");
        if (host) host.innerHTML = "";
        document.getElementById(elementId)?.remove();
        try {
          const rendered = await globalThis.mermaid.render(elementId, definition, host);
          const svg = String(rendered?.svg || "");
          document.getElementById(elementId)?.remove();
          return { ok: true, svg };
        } catch (err) {
          document.getElementById(elementId)?.remove();
          return { ok: false, error: String(err?.message || err).slice(0, 700) };
        }
      }, source, `probe${i}`);
      const errorSvg = outcome.ok && isMermaidErrorSvg(outcome.svg);
      results.push({
        source,
        ok: Boolean(outcome.ok) && !errorSvg,
        error: errorSvg ? "Mermaid 语法错误" : String(outcome.error || ""),
        svg: outcome.ok ? outcome.svg : "",
      });
    }
    return results;
  } finally {
    await browser.close();
  }
}

/**
 * Render Mermaid to a PNG (phone) and a flutter_svg-safe SVG (installed builds).
 */
export async function renderMermaidSvg({
  code,
  theme = "default",
  backgroundColor = "transparent",
  workspaceRoot,
  useCache = true,
}) {
  const trimmed = normalizeMermaidSource(code);
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
      return { id, svg: cached.svg, png: cached.png, cached: true };
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

  const { svg, png } = await renderWithPuppeteer(trimmed, paint, assets);
  if (useCache && workspaceRoot) {
    await mkdir(paths.dir, { recursive: true });
    await Promise.all([
      writeFile(paths.svg, svg, "utf8"),
      writeFile(paths.png, png),
    ]);
  }
  return { id, svg, png, cached: false };
}
