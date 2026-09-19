import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

function nodeExecutableCandidates() {
  const out = [];
  const push = (value) => {
    const p = String(value || "").trim();
    if (p && !out.includes(p)) out.push(p);
  };
  push(process.env.WENXIANG_NODE);
  push(process.execPath);
  if (process.platform === "win32") {
    push(path.join(process.env.ProgramFiles || "C:\\Program Files", "nodejs", "node.exe"));
    const pf86 = process.env["ProgramFiles(x86)"];
    if (pf86) push(path.join(pf86, "nodejs", "node.exe"));
  }
  push(whichSync("node"));
  return out;
}

/** Absolute node binary for spawning ACP (companion may start with a minimal PATH). */
export function resolveNodeExecutable() {
  for (const candidate of nodeExecutableCandidates()) {
    if (existsSync(candidate)) return path.normalize(candidate);
  }
  const fallback = nodeExecutableCandidates()[0] || "node";
  return path.normalize(fallback);
}

export function envWithNodeOnPath(env = process.env) {
  const next = { ...env };
  const node = resolveNodeExecutable();
  if (!node) return next;
  const dir = path.dirname(node);
  const key = process.platform === "win32" ? "Path" : "PATH";
  const cur = String(next[key] || "");
  const parts = cur.split(path.delimiter).filter(Boolean);
  const norm = (p) => path.normalize(p).toLowerCase();
  if (!parts.some((p) => norm(p) === norm(dir))) {
    next[key] = cur ? `${dir}${path.delimiter}${cur}` : dir;
  }
  return next;
}

export function whichSync(bin) {
  if (!bin) return "";
  if (bin.includes("/") || bin.includes("\\")) {
    return existsSync(bin) ? bin : "";
  }
  const nodeDir = (() => {
    const exec = String(process.execPath || "").trim();
    if (exec && existsSync(exec)) return path.dirname(exec);
    return "";
  })();
  const dirs = [
    ...(process.env.PATH || "").split(path.delimiter),
    nodeDir,
    path.join(process.env.APPDATA || "", "npm"),
    path.join(os.homedir(), ".local", "bin"),
    path.join(os.homedir(), "AppData", "Local", "cursor-agent"),
    path.join(process.env.LOCALAPPDATA || "", "cursor-agent"),
    path.join(process.env.LOCALAPPDATA || "", "Programs", "cursor"),
  ].filter(Boolean);

  const exts =
    process.platform === "win32"
      ? (process.env.PATHEXT || ".EXE;.CMD;.BAT;.COM").split(";").filter(Boolean)
      : [""];

  for (const dir of dirs) {
    const exact = path.join(dir, bin);
    if (existsSync(exact)) return exact;
    for (const ext of exts) {
      if (!ext) continue;
      const withExt = path.join(dir, `${bin}${ext}`);
      if (existsSync(withExt)) return withExt;
    }
  }
  return "";
}
