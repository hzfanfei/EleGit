import { detectCursorEngine } from "./acp.js";

export { detectCursorEngine } from "./acp.js";
export { whichSync } from "./which.js";
export { buildAcpPrompt, buildBookAcpPrompt } from "./acp.js";

export function streamOptsFromEnv() {
  const rawSize = String(process.env.WENXIANG_STREAM_CHUNK_SIZE ?? "0").trim();
  const rawDelay = String(process.env.WENXIANG_STREAM_DELAY_MS ?? "0").trim();
  const chunkSize = Number.parseInt(rawSize, 10);
  const delayMs = Number.parseInt(rawDelay, 10);
  return {
    chunkSize: Number.isFinite(chunkSize) && chunkSize > 0 ? chunkSize : 0,
    delayMs: Number.isFinite(delayMs) && delayMs >= 0 ? delayMs : 0,
  };
}

export async function* streamText(text, { chunkSize = 2, delayMs = 8, signal } = {}) {
  const chars = [...String(text || "")];
  if (chars.length <= chunkSize) {
    if (chars.length && !signal?.aborted) yield chars.join("");
    return;
  }
  for (let i = 0; i < chars.length; i += chunkSize) {
    if (signal?.aborted) return;
    yield chars.slice(i, i + chunkSize).join("");
    if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
  }
}

export function buildCursorPrompt({ question, history, context }) {
  const historyText = (history || [])
    .slice(-8)
    .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
    .join("\n");
  return [
    "You are 问象, a local repo progress assistant running on the user's computer.",
    "Answer in Simplified Chinese unless the user writes in another language.",
    "Be concise and efficient: lead with the direct answer; use short paragraphs or bullets; skip preamble, filler, and long recaps unless the user asks for detail.",
    "Use ONLY the GitHub facts and local checkout facts below. If something is missing, say so.",
    "Do not invent commits, PRs, files, or dates. Prefer the local checkout when it disagrees with stale memory.",
    "",
    "=== GitHub + local checkout context ===",
    context,
    "",
    historyText ? `=== Recent chat ===\n${historyText}\n` : "",
    `=== Question ===\n${question}`,
  ]
    .filter(Boolean)
    .join("\n");
}

export function synthesizeLocalAnswer({ question, progress, context, local }) {
  const q = (question || "").toLowerCase();
  const wantPr = /pr|pull|合并|拉取/.test(q);
  const wantIssue = /issue|问题|缺陷|bug/.test(q);
  const sections = [];

  sections.push(
    `**${progress.repo.fullName}**  \n最近推送 ${progress.repo.pushedAt || "未知"}，默认分支 \`${progress.repo.defaultBranch}\`。`,
  );

  if (!wantIssue && progress.commits.length) {
    const shown = progress.commits.slice(0, wantPr ? 5 : 8);
    sections.push("## 最近提交");
    sections.push(
      shown.map((c) => `- ${c.date.slice(0, 10)} ${c.author}：${c.message}`).join("\n"),
    );
  }

  if ((wantPr || !wantIssue) && progress.pulls.length) {
    sections.push(`## 开放 PR（${progress.pulls.length}）`);
    sections.push(
      progress.pulls
        .slice(0, 8)
        .map((p) => `- #${p.number} ${p.draft ? "[草稿] " : ""}${p.title}（${p.user}）`)
        .join("\n"),
    );
  } else if (wantPr) {
    sections.push("当前没有开放的 Pull Request。");
  }

  if (wantIssue || (!wantPr && progress.issues.length)) {
    if (progress.issues.length) {
      sections.push(`## 开放 Issue（${progress.issues.length}）`);
      sections.push(
        progress.issues
          .slice(0, 8)
          .map((i) => `- #${i.number} ${i.title}`)
          .join("\n"),
      );
    } else if (wantIssue) {
      sections.push("当前没有开放的 Issue。");
    }
  }

  if (local?.present) {
    const wantCode = /readme|文件|代码|怎么|启动|目录|checkout|本地/.test(q);
    sections.push(
      `## 本机目录\n\`${local.path}\`（${local.branch || "?"} @ \`${local.head || "?"}\`）`,
    );
    if (local.log && ((!wantPr && !wantIssue) || wantCode)) {
      sections.push("## 本地 git log");
      sections.push(
        local.log
          .split("\n")
          .slice(0, 8)
          .map((line) => `- ${line}`)
          .join("\n"),
      );
    }
    if (wantCode && local.files?.length) {
      sections.push("## 本机文件（节选）");
      sections.push(local.files.slice(0, 16).map((f) => `- \`${f}\``).join("\n"));
    }
    if (wantCode && local.readme) {
      sections.push("## README 摘录");
      sections.push(`\`\`\`\n${local.readme.slice(0, 800)}\n\`\`\``);
    }
  }

  if (!progress.commits.length && !progress.pulls.length && !progress.issues.length && !local?.present) {
    sections.push("GitHub 没有返回可见的提交、PR 或 Issue。请确认 token 对这个仓库有读权限。");
  }

  sections.push(
    local?.present
      ? "以上内容来自本机 GitHub API 与 ~/问象 目录，不是编造的演示数据。"
      : "以上内容全部来自本机调用的 GitHub API，不是编造的演示数据。",
  );
  return sections.join("\n\n");
}

export function synthesizeBookAnswer({ question, book, bookContext, local }) {
  const q = (question || "").toLowerCase();
  const sections = [`**${book.title || book.id}**`];
  if (book.author) sections.push(`作者：${book.author}`);
  if (local?.present) {
    sections.push(`## 本机缓存\n\`${local.path}\``);
  }
  if (bookContext) {
    const excerpt = bookContext.split("Text excerpt")[1]?.trim().slice(0, 1200);
    if (excerpt && /内容|章节|讲|谁|什么|quote|read/i.test(q)) {
      sections.push("## 书摘（节选）", excerpt);
    }
  }
  sections.push("以上内容来自本机 EPUB 缓存。若需更准的回答，请确认 Cursor ACP 可用。");
  return sections.join("\n\n");
}

export async function* streamAnswer({
  question,
  history,
  progress,
  context,
  local,
  session,
  sessions,
  githubContext,
  bookContext,
  buildPrompt,
  synthesize = synthesizeLocalAnswer,
  detectEngine = detectCursorEngine,
  streamOpts = streamOptsFromEnv(),
  signal,
  agentMode = false,
}) {
  const opts = { ...streamOpts, signal };
  const engine = detectEngine();
  if (engine && sessions && session) {
    yield { type: "start", engine: "acp" };
    const queue = [];
    let notify;
    let finished = false;
    let fail = null;
    let full = "";
    sessions
      .prompt(session, {
        question,
        history,
        githubContext: githubContext || context,
        bookContext,
        cwd: local?.present ? local.path : undefined,
        buildPrompt,
        agentMode,
        onDelta: (chunk) => {
          full += chunk;
          queue.push(chunk);
          notify?.();
        },
      })
      .then(() => {
        finished = true;
        notify?.();
      })
      .catch((err) => {
        fail = err;
        finished = true;
        notify?.();
      });
    while (!finished || queue.length) {
      if (signal?.aborted) {
        sessions.cancel?.(session).catch(() => {});
        return;
      }
      if (!queue.length) {
        await new Promise((resolve) => {
          notify = resolve;
        });
        notify = undefined;
        continue;
      }
      const piece = queue.shift();
      if (piece) yield { type: "delta", text: piece };
    }
    if (!fail && full) {
      yield { type: "done", engine: "acp", answer: full, sessionId: session.id };
      return;
    }
    const fallback = `${synthesize({ question, progress, context, local, bookContext })}\n\n（本机 ACP 调用失败：${fail?.message || "empty output"}。已回退到本地进度适配器。）`;
    yield { type: "start", engine: "local-progress" };
    yield* prefixDeltas(fallback, opts);
    if (signal?.aborted) return;
    yield { type: "done", engine: "local-progress", answer: fallback, sessionId: session.id };
    return;
  }
  const answer = synthesize({ question, progress, context, local, bookContext });
  yield { type: "start", engine: "local-progress" };
  yield* prefixDeltas(answer, opts);
  if (signal?.aborted) return;
  yield { type: "done", engine: "local-progress", answer, sessionId: session?.id };
}

async function* prefixDeltas(text, streamOpts) {
  const chunkSize = streamOpts?.chunkSize ?? 0;
  if (!chunkSize || chunkSize <= 0) {
    const whole = String(text || "");
    if (whole && !streamOpts?.signal?.aborted) yield { type: "delta", text: whole };
    return;
  }
  for await (const piece of streamText(text, { ...streamOpts, chunkSize })) {
    yield { type: "delta", text: piece };
  }
}

export async function answerQuestion(opts) {
  let last = { engine: "local-progress", answer: "" };
  for await (const event of streamAnswer(opts)) {
    if (event.type === "done") last = { engine: event.engine, answer: event.answer, sessionId: event.sessionId };
  }
  return last;
}
