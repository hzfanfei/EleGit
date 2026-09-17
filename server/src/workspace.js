import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, readdir, readFile, rm } from "node:fs/promises";
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

export const GIT_SYNC_AUTH_ZH =
  "无法拉取更新：本机 Git 未能认证 GitHub。请在本机终端进入该仓库目录执行 git pull，或在问象里重新登录 GitHub。";

export function gitAuthConfigArgs(token) {
  const value = String(token || "");
  if (!value) return [];
  const basic = Buffer.from(`x-access-token:${value}`, "utf8").toString("base64");
  return ["-c", `http.extraHeader=Authorization: Basic ${basic}`];
}

function zhGitError(message, text, extra = {}) {
  const err = new Error(message);
  err.detail = text;
  Object.assign(err, extra);
  return err;
}

export function gitFailure(output, code = 1) {
  const text = String(output || "").trim();
  if (isGithubGitPermissionDenied(text)) {
    return zhGitError(GITHUB_GIT_FORBIDDEN_ZH, text, {
      status: 403,
      code: "github_git_forbidden",
    });
  }
  if (/already exists and is not an empty directory/i.test(text)) {
    return zhGitError("本机目录不完整。请重试。", text, { code: "checkout_dirty" });
  }
  if (/repository .* not found|remote: repository not found/i.test(text)) {
    return zhGitError("找不到这个仓库。", text, { status: 404, code: "repo_not_found" });
  }
  if (/could not resolve host|name or service not known|failed to connect|network is unreachable/i.test(text)) {
    return zhGitError("连不上 GitHub。", text, { code: "git_network" });
  }
  if (/timed out/i.test(text)) {
    return zhGitError("克隆超时。请重试。", text, { code: "git_timeout" });
  }
  if (text === "cancelled" || /operation cancelled|signal: cancelled/i.test(text)) {
    return zhGitError("已取消", text, { code: "cancelled" });
  }
  return zhGitError("克隆失败。请重试。", text || `git exited ${code}`, { code: "git_failed" });
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

export function isCheckoutPresent(workspaceRoot, owner, repo) {
  const dest = checkoutPath(workspaceRoot, owner, repo);
  return existsSync(path.join(dest, ".git"));
}

export async function detectDefaultBranch(dest) {
  try {
    const sym = await runGit(["symbolic-ref", "refs/remotes/origin/HEAD"], { cwd: dest });
    const match = sym.match(/refs\/remotes\/origin\/(.+)/);
    if (match?.[1]) return match[1];
  } catch {
    // fall through
  }
  for (const name of ["main", "master"]) {
    try {
      await runGit(["rev-parse", `origin/${name}`], { cwd: dest });
      return name;
    } catch {
      // try next
    }
  }
  const head = await runGit(["rev-parse", "--abbrev-ref", "HEAD"], { cwd: dest }).catch(
    () => "main",
  );
  return head === "HEAD" ? "main" : head;
}

async function revParseRef(ref, dest) {
  try {
    return await runGit(["rev-parse", ref], { cwd: dest });
  } catch {
    return "";
  }
}

export async function getCheckoutSyncStatus({
  workspaceRoot,
  owner,
  repo,
  defaultBranch = "main",
  token,
  fetchRemote = true,
  signal,
} = {}) {
  const dest = checkoutPath(workspaceRoot, owner, repo);
  const present = existsSync(path.join(dest, ".git"));
  if (!present) {
    return {
      present: false,
      path: dest,
      syncState: "missing",
      upToDate: false,
      behind: 0,
      ahead: 0,
      defaultBranch,
    };
  }

  const branch = (await runGit(["rev-parse", "--abbrev-ref", "HEAD"], { cwd: dest, signal }).catch(
    () => "",
  )) || defaultBranch;
  const headFull = await revParseRef("HEAD", dest);
  const head = headFull ? headFull.slice(0, 7) : "";

  let fetchError = "";
  if (fetchRemote) {
    try {
      await runGit(["fetch", "--depth", "50", "origin"], { cwd: dest, token, signal });
    } catch (err) {
      fetchError = err?.message || String(err);
      if (err?.code === "github_git_forbidden") {
        return {
          present: true,
          path: dest,
          branch,
          head,
          syncState: "auth_required",
          upToDate: false,
          behind: 0,
          ahead: 0,
          defaultBranch,
          fetchError: GIT_SYNC_AUTH_ZH,
        };
      }
    }
  }

  const track = defaultBranch || branch;
  const remoteRef = `origin/${track}`;
  const remoteHeadFull = await revParseRef(remoteRef, dest);
  const remoteHead = remoteHeadFull ? remoteHeadFull.slice(0, 7) : "";

  let ahead = 0;
  let behind = 0;
  if (headFull && remoteHeadFull) {
    const counts = await runGit(["rev-list", "--left-right", "--count", `HEAD...${remoteRef}`], {
      cwd: dest,
      signal,
    }).catch(() => "0\t0");
    const parts = counts.split(/\s+/);
    ahead = Number.parseInt(parts[0], 10) || 0;
    behind = Number.parseInt(parts[1], 10) || 0;
  }

  let syncState = "unknown";
  let upToDate = false;
  if (headFull && remoteHeadFull && headFull === remoteHeadFull) {
    syncState = "current";
    upToDate = true;
  } else if (behind > 0 && ahead === 0) {
    syncState = "behind";
  } else if (ahead > 0 && behind === 0) {
    syncState = "ahead";
    upToDate = true;
  } else if (ahead > 0 && behind > 0) {
    syncState = "diverged";
  } else if (fetchError && !remoteHeadFull) {
    syncState = "unknown";
  } else if (remoteHeadFull) {
    syncState = "current";
    upToDate = behind === 0;
  }

  return {
    present: true,
    path: dest,
    branch,
    head,
    remoteHead,
    syncState,
    upToDate,
    behind,
    ahead,
    defaultBranch: track,
    fetchError: fetchError && syncState === "unknown" ? fetchError : "",
  };
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
  let existed = existsSync(path.join(dest, ".git"));
  if (!existed && existsSync(dest)) {
    await rm(dest, { recursive: true, force: true });
  }
  existed = existsSync(path.join(dest, ".git"));
  if (!existed) {
    try {
      await runGit(["clone", "--depth", "50", remote, dest], { token, signal });
    } catch (err) {
      if (!existsSync(path.join(dest, ".git"))) {
        await rm(dest, { recursive: true, force: true }).catch(() => {});
      }
      throw err;
    }
  } else {
    const syncToken = undefined;
    await runGit(["remote", "set-url", "origin", remote], { cwd: dest, signal });
    const sync = await getCheckoutSyncStatus({
      workspaceRoot,
      owner,
      repo,
      defaultBranch,
      token: syncToken,
      fetchRemote: true,
      signal,
    });
    if (sync.syncState === "auth_required") {
      throw zhGitError(GIT_SYNC_AUTH_ZH, sync.fetchError, {
        code: "git_sync_auth",
        status: 403,
      });
    }
    if (!sync.upToDate && sync.behind > 0) {
      try {
        await runGit(["checkout", defaultBranch], { cwd: dest, signal });
        await runGit(["pull", "--ff-only", "origin", defaultBranch], {
          cwd: dest,
          token: syncToken,
          signal,
        });
      } catch (err) {
        if (err?.code === "cancelled") throw err;
        if (err?.code === "github_git_forbidden") {
          throw zhGitError(GIT_SYNC_AUTH_ZH, err.detail, {
            code: "git_sync_auth",
            status: 403,
          });
        }
        // Keep the existing checkout if the default branch cannot fast-forward.
      }
    }
  }
  const local = await snapshotCheckout(dest);
  if (!local?.present) {
    throw zhGitError("仓库没有完整写到本机。请重试。", dest, { code: "checkout_missing" });
  }
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
