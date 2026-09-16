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

export const GITHUB_GIT_FORBIDDEN_ZH =
  "无法访问该仓库：GitHub 返回 403。常见原因：仓库为私有且当前登录无权克隆、OAuth 未授予 repo 权限，或组织启用了 SSO 但尚未授权问象。请在 GitHub 授权中勾选 repo，并完成组织 SSO 授权后重试。";

export function gitAuthConfigArgs(token) {
  const value = String(token || "");
  if (!value) return [];
  const basic = Buffer.from(`x-access-token:${value}`, "utf8").toString("base64");
  return ["-c", `http.extraHeader=Authorization: Basic ${basic}`];
}

export function gitFailure(output, code = 1) {
  const text = String(output || "").trim();
  if (isGithubGitPermissionDenied(text)) {
    const err = new Error(GITHUB_GIT_FORBIDDEN_ZH);
    err.status = 403;
    err.code = "github_git_forbidden";
    err.detail = text;
    return err;
  }
  return new Error(text || `git exited ${code}`);
}

function isGithubGitPermissionDenied(text) {
  if (/\b403\b/.test(text)) return true;
  if (/Authentication failed/i.test(text)) return true;
  if (/Write access to repository not granted/i.test(text)) return true;
  if (/SAML|SSO enforcement/i.test(text)) return true;
  return false;
}

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

export function runGit(args, { cwd, token, timeoutMs = 180_000, signal } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      const err = new Error("cancelled");
      err.code = "cancelled";
      reject(err);
      return;
    }
    const env = { ...process.env, GIT_TERMINAL_PROMPT: "0" };
    const extra = gitAuthConfigArgs(token);
    const child = spawn("git", [...extra, ...args], {
      cwd,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const done = (err, value) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener?.("abort", onAbort);
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(value);
    };
    const onAbort = () => {
      child.kill("SIGTERM");
      const err = new Error("cancelled");
      err.code = "cancelled";
      done(err);
    };
    signal?.addEventListener?.("abort", onAbort, { once: true });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      done(new Error(`git timed out: ${args.join(" ")}`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", (err) => {
      done(err);
    });
    child.on("close", (code) => {
      if (signal?.aborted) {
        const err = new Error("cancelled");
        err.code = "cancelled";
        done(err);
        return;
      }
      if (code !== 0) {
        done(gitFailure(stderr || stdout, code));
        return;
      }
      done(null, stdout.trim());
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
  signal,
}) {
  const dest = checkoutPath(workspaceRoot, owner, repo);
  await mkdir(path.dirname(dest), { recursive: true });
  const remote = cloneUrl || `https://github.com/${owner}/${repo}.git`;
  const existed = existsSync(path.join(dest, ".git"));
  if (!existed) {
    await runGit(["clone", "--depth", "50", remote, dest], { token, signal });
  } else {
    await runGit(["remote", "set-url", "origin", remote], { cwd: dest, signal });
    await runGit(["fetch", "--depth", "50", "origin"], { cwd: dest, token, signal });
    try {
      await runGit(["checkout", defaultBranch], { cwd: dest, signal });
      await runGit(["pull", "--ff-only", "origin", defaultBranch], {
        cwd: dest,
        token,
        signal,
      });
    } catch (err) {
      if (err?.code === "cancelled") throw err;
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
