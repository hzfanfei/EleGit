import { spawn } from "node:child_process";
import { existsSync } from "node:fs";

const CURSOR_CANDIDATES = [
  { bin: "cursor-agent", args: (prompt) => ["-p", prompt, "--output-format", "text"] },
  { bin: "agent", args: (prompt) => ["-p", prompt] },
  { bin: "cursor", args: (prompt) => ["agent", "-p", prompt] },
];

export function whichSync(bin) {
  if (bin.includes("/") && existsSync(bin)) return bin;
  const pathVar = process.env.PATH || "";
  for (const dir of pathVar.split(":")) {
    if (!dir) continue;
    const candidate = `${dir}/${bin}`;
    if (existsSync(candidate)) return candidate;
  }
  return "";
}

export function detectCursorEngine() {
  for (const candidate of CURSOR_CANDIDATES) {
    const resolved = whichSync(candidate.bin);
    if (resolved) {
      return { id: candidate.bin, path: resolved, argsFor: candidate.args };
    }
  }
  return null;
}

function runCommand(file, args, { timeoutMs = 120_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(file, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`Cursor CLI timed out after ${timeoutMs}ms`));
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
        reject(new Error(stderr.trim() || stdout.trim() || `${file} exited ${code}`));
        return;
      }
      resolve((stdout || stderr).trim());
    });
  });
}

export function buildCursorPrompt({ question, history, context }) {
  const historyText = (history || [])
    .slice(-8)
    .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
    .join("\n");
  return [
    "You are 问象, a local repo progress assistant running on the user's computer.",
    "Answer in Simplified Chinese unless the user writes in another language.",
    "Use ONLY the GitHub facts below. If something is missing, say so. Do not invent commits, PRs, or dates.",
    "",
    "=== GitHub context ===",
    context,
    "",
    historyText ? `=== Recent chat ===\n${historyText}\n` : "",
    `=== Question ===\n${question}`,
  ]
    .filter(Boolean)
    .join("\n");
}

export function synthesizeLocalAnswer({ question, progress, context }) {
  const q = (question || "").toLowerCase();
  const wantPr = /pr|pull|合并|拉取/.test(q);
  const wantIssue = /issue|问题|缺陷|bug/.test(q);
  const sections = [];

  sections.push(
    `【${progress.repo.fullName}】最近推送 ${progress.repo.pushedAt || "未知"}，默认分支 ${progress.repo.defaultBranch}。`,
  );

  if (!wantIssue && progress.commits.length) {
    const shown = progress.commits.slice(0, wantPr ? 5 : 8);
    sections.push("最近提交：");
    sections.push(
      shown.map((c) => `· ${c.date.slice(0, 10)} ${c.author}：${c.message}`).join("\n"),
    );
  }

  if ((wantPr || !wantIssue) && progress.pulls.length) {
    sections.push(`开放 PR（${progress.pulls.length}）：`);
    sections.push(
      progress.pulls
        .slice(0, 8)
        .map((p) => `· #${p.number} ${p.draft ? "[草稿] " : ""}${p.title}（${p.user}）`)
        .join("\n"),
    );
  } else if (wantPr) {
    sections.push("当前没有开放的 Pull Request。");
  }

  if (wantIssue || (!wantPr && progress.issues.length)) {
    if (progress.issues.length) {
      sections.push(`开放 Issue（${progress.issues.length}）：`);
      sections.push(
        progress.issues
          .slice(0, 8)
          .map((i) => `· #${i.number} ${i.title}`)
          .join("\n"),
      );
    } else if (wantIssue) {
      sections.push("当前没有开放的 Issue。");
    }
  }

  if (!progress.commits.length && !progress.pulls.length && !progress.issues.length) {
    sections.push("GitHub 没有返回可见的提交、PR 或 Issue。请确认 token 对这个仓库有读权限。");
  }

  sections.push("以上内容全部来自本机调用的 GitHub API，不是编造的演示数据。");
  return sections.join("\n\n");
}

export async function answerQuestion({ question, history, progress, context }) {
  const engine = detectCursorEngine();
  const prompt = buildCursorPrompt({ question, history, context });
  if (engine) {
    try {
      const text = await runCommand(engine.path, engine.argsFor(prompt));
      if (text) {
        return { engine: engine.id, answer: text };
      }
    } catch (err) {
      const fallback = synthesizeLocalAnswer({ question, progress, context });
      return {
        engine: "local-progress",
        answer: `${fallback}\n\n（本机探测到 ${engine.id}，但调用失败：${err.message}。已回退到 GitHub 进度适配器。）`,
      };
    }
  }
  return {
    engine: "local-progress",
    answer: synthesizeLocalAnswer({ question, progress, context }),
  };
}
