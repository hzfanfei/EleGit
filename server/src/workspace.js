import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readdir, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const SKIP_DIR = new Set([
  ".git",
  "node_modules",
  ".dart_tool",
  "build",
  "dist",
  ".idea",
  ".venv",
  "__pycache__",
]);

export function defaultWorkspaceRoot() {
  return process.env.WENXIANG_WORKSPACE || path.join(os.homedir(), "问象");
}

export function safeSegment(name, label) {
  const text = String(name || "");
  if (!/^[A-Za-z0-9._-]+$/.test(text) || text === "." || text === "..") {
    const err = new Error(`Invalid ${label}`);
    err.status = 400;
    throw err;
  }
  return text;
}

export function checkoutPath(workspaceRoot, owner, repo) {
  return path.join(
    workspaceRoot,
    safeSegment(owner, "owner"),
    safeSegment(repo, "repo"),
  );
}

function runGit(args, { cwd, token, timeoutMs = 180_000 } = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
    const extra = [];
    if (token) extra.push("-c", `http.extraHeader=Authorization: Bearer ${token}`);
    const child = spawn("git", [...extra, ...args], {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`git timed out: ${args.join(" ")}`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error((stderr || stdout).trim() || `git exited ${code}`));
        return;
      }
      resolve(stdout.trim());
    });
  });
}

export async function ensureCheckout({
  workspaceRoot,
  owner,
  repo,
  token,
  cloneUrl,
  defaultBranch = "main",
}) {
  const dest = checkoutPath(workspaceRoot, owner, repo);
  await mkdir(path.dirname(dest), { recursive: true });
  const remote = cloneUrl || `https://github.com/${owner}/${repo}.git`;
  const existed = existsSync(path.join(dest, ".git"));
  if (!existed) {
    await runGit(["clone", "--depth", "50", remote, dest], { token });
  } else {
    await runGit(["remote", "set-url", "origin", remote], { cwd: dest });
    await runGit(["fetch", "--depth", "50", "origin"], { cwd: dest, token });
    try {
      await runGit(["checkout", defaultBranch], { cwd: dest });
      await runGit(["pull", "--ff-only", "origin", defaultBranch], {
        cwd: dest,
        token,
      });
    } catch {
      // Keep the existing checkout if the default branch cannot fast-forward.
    }
  }
  const local = await snapshotCheckout(dest);
  return { dest, existed, local };
}

async function listTree(root, { maxEntries = 80 } = {}) {
  const out = [];
  async function walk(rel, depth) {
    if (out.length >= maxEntries) return;
    const abs = path.join(root, rel);
    let entries = [];
    try {
      entries = await readdir(abs, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (out.length >= maxEntries) return;
      if (SKIP_DIR.has(entry.name) || entry.name.startsWith(".git")) continue;
      const next = rel ? `${rel}/${entry.name}` : entry.name;
      out.push(entry.isDirectory() ? `${next}/` : next);
      if (entry.isDirectory() && depth < 2) await walk(next, depth + 1);
    }
  }
  await walk("", 0);
  return out;
}

export async function snapshotCheckout(dest) {
  if (!existsSync(path.join(dest, ".git"))) {
    return { path: dest, present: false };
  }
  const [branch, head, log, status] = await Promise.all([
    runGit(["rev-parse", "--abbrev-ref", "HEAD"], { cwd: dest }).catch(() => ""),
    runGit(["rev-parse", "--short", "HEAD"], { cwd: dest }).catch(() => ""),
    runGit(["log", "-15", "--format=%h %ad %an %s", "--date=short"], { cwd: dest }).catch(
      () => "",
    ),
    runGit(["status", "--short"], { cwd: dest }).catch(() => ""),
  ]);
  let readme = "";
  for (const name of ["README.md", "README.MD", "readme.md", "README"]) {
    try {
      readme = (await readFile(path.join(dest, name), "utf8")).slice(0, 4000);
      break;
    } catch {
      // try next
    }
  }
  const files = await listTree(dest);
  return {
    present: true,
    path: dest,
    branch,
    head,
    log,
    status: status.slice(0, 1500),
    files,
    readme,
  };
}

export function formatLocalContext(local) {
  if (!local?.present) {
    return "Local checkout: not present yet.";
  }
  const lines = [
    `Local checkout: ${local.path}`,
    `Branch: ${local.branch || "unknown"} @ ${local.head || "unknown"}`,
    "",
    "Local git log:",
    local.log || "(empty)",
    "",
    "Working tree (git status --short):",
    local.status || "(clean)",
    "",
    "Files:",
    ...(local.files || []).slice(0, 80).map((f) => `- ${f}`),
  ];
  if (local.readme) {
    lines.push("", "README excerpt:", local.readme);
  }
  return lines.join("\n");
}
