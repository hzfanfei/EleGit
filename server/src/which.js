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

function gitExecutableCandidates() {
  const out = [];
  const push = (value) => {
    const p = String(value || "").trim();
    if (p && !out.includes(p)) out.push(p);
  };
  push(process.env.WENXIANG_GIT);
  if (process.platform === "win32") {
    const pf = process.env.ProgramFiles || "C:\\Program Files";
    push(path.join(pf, "Git", "cmd", "git.exe"));
    push(path.join(pf, "Git", "bin", "git.exe"));
    const pf86 = process.env["ProgramFiles(x86)"];
    if (pf86) {
      push(path.join(pf86, "Git", "cmd", "git.exe"));
      push(path.join(pf86, "Git", "bin", "git.exe"));
    }
  }
  push(whichSync("git"));
  return out;
}

/** Absolute git binary (companion may start with a minimal PATH). */
export function resolveGitExecutable() {
  for (const candidate of gitExecutableCandidates()) {
    if (existsSync(candidate)) return path.normalize(candidate);
  }
  const fallback = gitExecutableCandidates()[0] || "git";
  return path.normalize(fallback);
}

function prependPathDir(env, dir) {
  const next = { ...env };
  const folder = String(dir || "").trim();
  if (!folder) return next;
  const key = process.platform === "win32" ? "Path" : "PATH";
  const cur = String(next[key] || "");
  const parts = cur.split(path.delimiter).filter(Boolean);
  const norm = (p) => path.normalize(p).toLowerCase();
  if (!parts.some((p) => norm(p) === norm(folder))) {
    next[key] = cur ? `${folder}${path.delimiter}${cur}` : folder;
  }
  return next;
}

export function envWithToolchainOnPath(env = process.env) {
  let next = { ...env };
  for (const bin of [resolveNodeExecutable(), resolveGitExecutable()]) {
    if (bin && existsSync(bin)) {
      next = prependPathDir(next, path.dirname(bin));
    }
  }
  return next;
}

export function envWithNodeOnPath(env = process.env) {
  return envWithToolchainOnPath(env);
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
  const gitDirs =
    process.platform === "win32"
      ? [
          path.join(process.env.ProgramFiles || "C:\\Program Files", "Git", "cmd"),
          path.join(process.env.ProgramFiles || "C:\\Program Files", "Git", "bin"),
        ]
      : [];
  const dirs = [
    ...(process.env.PATH || "").split(path.delimiter),
    nodeDir,
    ...gitDirs,
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
