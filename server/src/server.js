import { createServer } from "node:http";
import express from "express";
import cors from "cors";
import { corsOptions } from "./cors.js";
import { loadLocalEnv } from "./env.js";
import {
  setAcpEnginePreferences,
  resolveAgentCommand,
  buildBookAcpPrompt,
  createSessionStore,
  detectCursorEngine,
  sanitizeAcpEngine,
} from "./acp.js";
import { handleBookVoiceTurn } from "./book-voice-turn.js";
import { handleRepoVoiceTurn } from "./repo-voice-turn.js";
import { streamAnswer, synthesizeBookAnswer, answerReadyNotice } from "./ask.js";
import { setPhoneForeground, phoneInForeground } from "./phone-presence.js";
import { openSse, writeSse, writeSseSafe } from "./sse.js";
import {
  emptyRepoProgress,
  formatProgressContext,
  listRepos,
  pollDeviceFlow,
  startDeviceFlow,
  verifyToken,
} from "./github.js";
import { lanUrls } from "./network.js";
import {
  callbackHtml,
  createOAuthSessions,
  exchangeCode,
  suggestedCallbackUrls,
} from "./oauth.js";
import { isCancelled, requestSignal } from "./http-signal.js";
import { loadStore } from "./store.js";
import { createTunnelHealth } from "./tunnel-health.js";
import { createTunnelManager } from "./tunnel.js";
import {
  publicVoiceStatus,
  resolveTtsVoiceId,
  resolveVoiceConfig,
  sanitizeTtsVoice,
  sanitizeVoiceStack,
  setPreferredVoiceStack,
  voiceAfterStackSwitch,
  voiceMemoryKey,
  voiceStackOf,
  withTtsVoice,
} from "./voice-config.js";
import { ensureCosyVoiceTtsWorker, shutdownCosyVoiceTtsWorker } from "./cosyvoice-tts.js";
import { ensureFunasrAsrWorker, shutdownFunasrAsrWorker } from "./funasr-asr.js";
import { COMPANION_ALREADY_RUNNING } from "./keep-alive-policy.js";
import { bindCompanion } from "./listen.js";
import { attachSttGateway } from "./voice-stt-ws.js";
import { attachVoiceGateway, isVoiceCallEnabled } from "./voice-ws.js";
import { appendClientLogs } from "./client-logs.js";
import { runDiagnosticsProbe, synthesizeVoicePreview } from "./diagnostics.js";
import {
  checkoutPath,
  detectDefaultBranch,
  ensureCheckout,
  formatAcpContext,
  formatLocalContext,
  getCheckoutSyncStatus,
  isCheckoutPresent,
  listLocalRepos,
  snapshotCheckoutLite,
} from "./workspace.js";
import {
  bookSessionOwner,
  bookLocalView,
  booksDir,
  emptyBookProgress,
  ensureBookMaterialized,
  formatBookAcpContext,
  listBooks,
  loadBookReadingManifest,
  contentTypeForBookAsset,
  openBookFileStream,
  readBookChapterMarkdown,
  readCachedCover,
  resolveBook,
  resolveBookCacheAssetPath,
} from "./books.js";
import { envWithNodeOnPath, resolveGitExecutable, resolveNodeExecutable } from "./which.js";
import {
  ensureStaticDir,
  deleteStaticFile,
  listStaticFiles,
  openStaticFileStream,
  resolveStaticFile,
  staticContentDisposition,
  staticDir,
  staticDownloadAuthorized,
  staticFilesPrompt,
  contentTypeForStatic,
} from "./static-files.js";
import { clearInbox, listInbox, markInboxRead } from "./inbox.js";
import { attachNotifications, publishInboxNotice } from "./notifications.js";
import { stat } from "node:fs/promises";

loadLocalEnv();
process.env = envWithNodeOnPath(process.env);

const PORT = Number(process.env.WENXIANG_PORT || 8787);
const BIND = process.env.WENXIANG_BIND || "0.0.0.0";

const store = await loadStore();

function syncAcpEngineConfig(config) {
  const legacy = sanitizeAcpEngine(config.acpEngine);
  const envFallback = sanitizeAcpEngine(process.env.WENXIANG_ACP_ENGINE);
  const book =
    sanitizeAcpEngine(config.acpEngineBook) || legacy || envFallback || "claude";
  const repo =
    sanitizeAcpEngine(config.acpEngineRepo) || legacy || envFallback || "claude";
  config.acpEngineBook = book;
  config.acpEngineRepo = repo;
  config.acpEngine = repo;
  setAcpEnginePreferences({ book, repo });
  return { book, repo };
}

syncAcpEngineConfig(store.config);
setPreferredVoiceStack(store.config.voiceStack);

const sessions = createSessionStore({
  resolveCommand: () => resolveAgentCommand("repo"),
});
const bookSessions = createSessionStore({
  resolveCommand: () => resolveAgentCommand("book"),
});
const chatCancels = new Map();

function beginChatTurn(sessionId) {
  const prev = chatCancels.get(sessionId);
  prev?.abort();
  const ac = new AbortController();
  chatCancels.set(sessionId, ac);
  return ac;
}

function endChatTurn(sessionId, ac) {
  if (chatCancels.get(sessionId) === ac) chatCancels.delete(sessionId);
}

function trackUnwatched(res) {
  let gone = false;
  res.on("close", () => {
    if (!res.writableEnded) gone = true;
  });
  return () => gone || !phoneInForeground();
}

async function notifyFinishedAnswer({ notified, aborted, unwatched, answer, session, question, bookId }) {
  if (notified || aborted || !unwatched) return;
  try {
    await publishInboxNotice(
      store.config.workspaceRoot,
      answerReadyNotice(answer, { session, question, bookId }),
    );
  } catch {
    /* notification is best-effort */
  }
}
const oauth = createOAuthSessions();
const tunnel = createTunnelManager({
  port: PORT,
  getConfig: () => store.config,
});
const tunnelHealth = createTunnelHealth({
  getPublicUrl: () => store.config.publicUrl,
});

const app = express();
app.use(cors(corsOptions));
app.options("*", cors(corsOptions));
app.use(express.json({ limit: "1mb" }));

function sendError(res, err) {
  if (isCancelled(err)) {
    if (!res.headersSent) {
      res.status(499).json({ error: "已取消", code: "cancelled" });
    } else {
      res.end();
    }
    return;
  }
  const status = err.status && Number.isInteger(err.status) ? err.status : 500;
  res.status(status).json({
    error: err.message || "Internal error",
    code: err.code || undefined,
  });
}

function oauthReady() {
  return Boolean(store.config.githubClientId && store.config.githubClientSecret);
}

app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    name: "问象",
    service: "wenxiang",
    publicReachable: tunnelHealth.status().reachable,
  });
});

app.get(/^\/files\/(.+)$/, async (req, res) => {
  try {
    if (
      !staticDownloadAuthorized({
        token: req.query.token,
        headerKey: req.get("X-Wenxiang-Key"),
        staticToken: store.config.staticToken,
        apiKey: store.config.apiKey,
      })
    ) {
      res.status(401).json({ error: "下载链接无效", code: "static_unauthorized" });
      return;
    }
    const root = staticDir(store.config.workspaceRoot);
    const { relative, abs } = resolveStaticFile(root, req.params[0]);
    const info = await stat(abs);
    if (!info.isFile()) {
      res.status(404).json({ error: "文件不存在", code: "static_missing" });
      return;
    }
    res.setHeader("Content-Type", contentTypeForStatic(relative));
    res.setHeader("Content-Length", String(info.size));
    res.setHeader("Content-Disposition", staticContentDisposition(relative, relative));
    res.setHeader("Cache-Control", "private, no-cache");
    openStaticFileStream(abs).pipe(res);
  } catch (err) {
    if (err?.code === "ENOENT") {
      res.status(404).json({ error: "文件不存在", code: "static_missing" });
      return;
    }
    sendError(res, err);
  }
});

app.get("/oauth/github/callback", async (req, res) => {
  const state = String(req.query.state || "");
  const code = String(req.query.code || "");
  const ghError = String(req.query.error_description || req.query.error || "");
  const session = oauth.peek(state);
  if (!session) {
    res
      .status(400)
      .type("html")
      .send(callbackHtml({ ok: false, message: "登录会话无效或已过期。" }));
    return;
  }
  if (ghError || !code) {
    oauth.fail(state, ghError || "GitHub 未返回授权码");
    res
      .status(400)
      .type("html")
      .send(callbackHtml({ ok: false, message: ghError || "GitHub 未返回授权码。" }));
    return;
  }
  try {
    const token = await exchangeCode({
      clientId: store.config.githubClientId,
      clientSecret: store.config.githubClientSecret,
      code,
      redirectUri: session.redirectUri,
    });
    const user = await verifyToken(token);
    store.config.githubToken = token;
    store.config.githubUser = user;
    await store.save();
    oauth.complete(state);
    res.type("html").send(callbackHtml({ ok: true, message: `已登录 ${user.login}。` }));
  } catch (err) {
    oauth.fail(state, err.message);
    res.status(400).type("html").send(callbackHtml({ ok: false, message: err.message }));
  }
});

app.use("/v1", (req, res, next) => {
  if (req.method === "OPTIONS") {
    next();
    return;
  }
  const key = req.get("X-Wenxiang-Key") || "";
  if (!store.config.apiKey || key !== store.config.apiKey) {
    res.status(401).json({ error: "Missing or invalid X-Wenxiang-Key" });
    return;
  }
  next();
});

function githubToken() {
  return String(store.config.githubToken || "").trim();
}

function requireGithub(req, res, next) {
  if (!githubToken()) {
    res.status(401).json({ error: "GitHub is not connected. Sign in from the phone browser." });
    return;
  }
  next();
}

app.get("/v1/status", (_req, res) => {
  const cursorRepo = detectCursorEngine("repo");
  const cursorBook = detectCursorEngine("book");
  const lans = lanUrls(PORT);
  const tunnelStatus = tunnel.status();
  res.json({
    name: "问象",
    github: {
      connected: Boolean(githubToken()),
      user: store.config.githubUser,
      oauthReady: oauthReady(),
      callbackPath: "/oauth/github/callback",
      publicUrl: store.config.publicUrl,
      callbackUrls: suggestedCallbackUrls({
        lanUrls: lans,
        tunnelUrl: store.config.publicUrl || tunnelStatus.publicUrl,
      }),
      deviceFlowReady: Boolean(store.config.githubClientId),
    },
    workspace: {
      root: store.config.workspaceRoot,
      booksDir: booksDir(store.config.workspaceRoot),
      staticDir: staticDir(store.config.workspaceRoot),
    },
    cursor: {
      available: Boolean(cursorRepo),
      engine: cursorRepo?.id || null,
      mode: cursorRepo?.mode || null,
      model: cursorRepo?.model || null,
      transport: cursorRepo?.transport || null,
      preference: store.config.acpEngineRepo || "claude",
      preferences: {
        book: store.config.acpEngineBook || "claude",
        repo: store.config.acpEngineRepo || "claude",
      },
      fallback: "local-progress",
    },
    voice: publicVoiceStatus(withTtsVoice(resolveVoiceConfig(), store.config.ttsVoice)),
    books: (() => {
      const acp = cursorBook;
      return {
        engine: "acp",
        ready: Boolean(acp),
        model: acp?.model || null,
        preference: store.config.acpEngineBook || "claude",
      };
    })(),
    tunnel: tunnelStatus,
    tunnelHealth: tunnelHealth.status(),
    lanUrls: lans,
    port: PORT,
  });
});

app.post("/v1/github/oauth/start", (req, res) => {
  try {
    if (!oauthReady()) {
      res.status(400).json({
        error:
          "Copy the repo-root .env.example to .env and set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET. Register {WENXIANG_PUBLIC_URL}/oauth/github/callback.",
      });
      return;
    }
    const publicBaseUrl = store.config.publicUrl;
    const started = oauth.start({
      clientId: store.config.githubClientId,
      publicBaseUrl,
    });
    res.json(started);
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/github/oauth/status", (req, res) => {
  const state = String(req.query.state || "");
  const session = oauth.peek(state);
  if (!session) {
    res.status(404).json({ error: "Unknown or expired OAuth state" });
    return;
  }
  res.json({
    status: session.status,
    error: session.error || undefined,
    connected: session.status === "connected" && Boolean(githubToken()),
    user: session.status === "connected" ? store.config.githubUser : null,
  });
});

app.post("/v1/github/pat", async (req, res) => {
  try {
    const token = String(req.body?.token || "").trim();
    if (!token) {
      res.status(400).json({ error: "token is required" });
      return;
    }
    const user = await verifyToken(token);
    store.config.githubToken = token;
    store.config.githubUser = user;
    await store.save();
    res.json({ connected: true, user });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/github/device/start", async (_req, res) => {
  try {
    const data = await startDeviceFlow(store.config.githubClientId);
    res.json({
      deviceCode: data.device_code,
      userCode: data.user_code,
      verificationUri: data.verification_uri,
      verificationUriComplete: data.verification_uri_complete,
      interval: data.interval || 5,
      expiresIn: data.expires_in,
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/github/device/poll", async (req, res) => {
  try {
    const deviceCode = String(req.query.device_code || "");
    if (!deviceCode) {
      res.status(400).json({ error: "device_code is required" });
      return;
    }
    const data = await pollDeviceFlow(store.config.githubClientId, deviceCode);
    const user = await verifyToken(data.access_token);
    store.config.githubToken = data.access_token;
    store.config.githubUser = user;
    await store.save();
    res.json({ connected: true, user });
  } catch (err) {
    sendError(res, err);
  }
});

app.delete("/v1/github/session", async (_req, res) => {
  store.config.githubToken = "";
  store.config.githubUser = null;
  await store.save();
  res.json({ connected: false });
});

app.get("/v1/repos/local", async (req, res) => {
  try {
    const q = String(req.query.q || "");
    const repos = await listLocalRepos(store.config.workspaceRoot, q);
    res.json({ repos, source: "local" });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/repos", requireGithub, async (req, res) => {
  try {
    const repos = await listRepos(githubToken(), String(req.query.q || ""));
    res.json({ repos, source: "github" });
  } catch (err) {
    sendError(res, err);
  }
});

async function resolveDefaultBranch(owner, repo) {
  const dest = checkoutPath(store.config.workspaceRoot, owner, repo);
  if (isCheckoutPresent(store.config.workspaceRoot, owner, repo)) {
    return detectDefaultBranch(dest);
  }
  return "main";
}

async function checkoutRepo(owner, repo, signal, { fast = false } = {}) {
  const present = isCheckoutPresent(store.config.workspaceRoot, owner, repo);
  const defaultBranch = present ? await resolveDefaultBranch(owner, repo) : "main";
  const result = await ensureCheckout({
    workspaceRoot: store.config.workspaceRoot,
    owner,
    repo,
    defaultBranch,
    fetchRemote: !(fast && present),
    signal,
  });
  const progress = emptyRepoProgress(owner, repo, result.local?.branch || defaultBranch);
  return { progress, ...result };
}

app.get("/v1/repos/:owner/:repo/checkout-status", async (req, res) => {
  try {
    const { owner, repo } = req.params;
    let defaultBranch = String(req.query.branch || "").trim();
    if (!defaultBranch) {
      defaultBranch = await resolveDefaultBranch(owner, repo);
    }
    const status = await getCheckoutSyncStatus({
      workspaceRoot: store.config.workspaceRoot,
      owner,
      repo,
      defaultBranch,
      fetchRemote: req.query.fetch !== "0",
    });
    res.json(status);
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/repos/:owner/:repo/checkout", async (req, res) => {
  try {
    const { owner, repo } = req.params;
    const { progress, dest, existed, local } = await checkoutRepo(
      owner,
      repo,
      requestSignal(req, res),
    );
    if (detectCursorEngine("repo")) {
      sessions.warmRepo(owner, repo, dest).catch(() => {});
    }
    res.json({
      path: dest,
      existed,
      local,
      repo: progress?.repo,
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/repos/:owner/:repo/progress", async (req, res) => {
  try {
    const { progress, dest, local } = await checkoutRepo(req.params.owner, req.params.repo);
    res.json({ ...progress, checkout: { path: dest, ...local } });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/repos/:owner/:repo/sessions", (req, res) => {
  try {
    res.json(sessions.list(req.params.owner, req.params.repo));
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/repos/:owner/:repo/sessions", (req, res) => {
  try {
    const { owner, repo } = req.params;
    const view = sessions.create(owner, repo);
    const dest = checkoutPath(store.config.workspaceRoot, owner, repo);
    if (isCheckoutPresent(store.config.workspaceRoot, owner, repo)) {
      sessions.warmRepo(owner, repo, dest).catch(() => {});
    }
    res.status(201).json(view);
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/repos/:owner/:repo/sessions/warm", async (req, res) => {
  try {
    const { owner, repo } = req.params;
    const dest = checkoutPath(store.config.workspaceRoot, owner, repo);
    if (!isCheckoutPresent(store.config.workspaceRoot, owner, repo)) {
      res.json({ warmed: false, reason: "checkout_missing" });
      return;
    }
    const out = await sessions.warmRepo(owner, repo, dest);
    res.json(out);
  } catch (err) {
    sendError(res, err);
  }
});

app.delete("/v1/repos/:owner/:repo/sessions/:id", async (req, res) => {
  try {
    res.json(await sessions.close(req.params.owner, req.params.repo, req.params.id));
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/static", async (_req, res) => {
  try {
    const listed = await listStaticFiles(store.config.workspaceRoot, {
      publicUrl: store.config.publicUrl,
      token: store.config.staticToken,
    });
    res.json(listed);
  } catch (err) {
    sendError(res, err);
  }
});

app.delete("/v1/static", async (req, res) => {
  try {
    const rel = String(req.query.path || "").trim();
    if (!rel) {
      res.status(400).json({ error: "缺少 path", code: "static_path" });
      return;
    }
    res.json(await deleteStaticFile(store.config.workspaceRoot, rel));
  } catch (err) {
    if (err?.code === "ENOENT" || err?.code === "static_missing") {
      res.status(404).json({ error: "文件不存在", code: "static_missing" });
      return;
    }
    sendError(res, err);
  }
});

app.get("/v1/books", async (_req, res) => {
  try {
    const out = await listBooks(store.config.workspaceRoot);
    res.json({ booksDir: out.dir, books: out.books });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/books/:bookId/file", async (req, res) => {
  try {
    const book = await resolveBook(store.config.workspaceRoot, req.params.bookId);
    res.setHeader("Content-Type", "application/epub+zip");
    res.setHeader(
      "Content-Disposition",
      `attachment; filename="${encodeURIComponent(book.filename)}"`,
    );
    openBookFileStream(book.path).pipe(res);
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/books/:bookId/reading", async (req, res) => {
  try {
    const book = await resolveBook(store.config.workspaceRoot, req.params.bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const manifest = await loadBookReadingManifest(materialized);
    res.json({
      bookId: book.id,
      title: manifest.title || book.title,
      author: manifest.author || book.author,
      converter: manifest.converter || "plain",
      chapters: manifest.chapters || [],
      toc: manifest.toc || manifest.chapters || [],
      workspace: materialized.cacheDir,
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/books/:bookId/chapters/:filename", async (req, res) => {
  try {
    const book = await resolveBook(store.config.workspaceRoot, req.params.bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const markdown = await readBookChapterMarkdown(materialized, req.params.filename);
    res.setHeader("Content-Type", "text/markdown; charset=utf-8");
    res.send(markdown);
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/books/:bookId/asset", async (req, res) => {
  try {
    const book = await resolveBook(store.config.workspaceRoot, req.params.bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const abs = resolveBookCacheAssetPath(materialized, req.query.path);
    res.setHeader("Content-Type", contentTypeForBookAsset(abs));
    openBookFileStream(abs).pipe(res);
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/books/:bookId/cover", async (req, res) => {
  try {
    const book = await resolveBook(store.config.workspaceRoot, req.params.bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const cover = await readCachedCover(materialized.cacheDir);
    if (!cover) {
      res.status(404).json({ error: "Cover not found" });
      return;
    }
    const type =
      cover.ext === ".png"
        ? "image/png"
        : cover.ext === ".gif"
          ? "image/gif"
          : cover.ext === ".webp"
            ? "image/webp"
            : "image/jpeg";
    res.setHeader("Content-Type", type);
    openBookFileStream(cover.path).pipe(res);
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/books/:bookId/sessions", (req, res) => {
  try {
    const owner = bookSessionOwner();
    res.json(bookSessions.list(owner, req.params.bookId));
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/books/:bookId/sessions", (req, res) => {
  try {
    const owner = bookSessionOwner();
    const view = bookSessions.create(owner, req.params.bookId);
    res.status(201).json(view);
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/books/:bookId/sessions/warm", async (req, res) => {
  try {
    if (!detectCursorEngine("book")) {
      res.status(503).json({
        error: "问书需要本机 Claude Code 或 Cursor Agent（ACP）。请安装并登录所选助手。",
        code: "acp_unconfigured",
      });
      return;
    }
    const book = await resolveBook(store.config.workspaceRoot, req.params.bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const owner = bookSessionOwner();
    const sessionId = String(req.body?.sessionId || "").trim();
    const session = bookSessions.resolveForChat(owner, book.id, sessionId);
    await bookSessions.warm(session, materialized.cacheDir);
    res.json({
      warmed: true,
      engine: "acp",
      workspace: materialized.cacheDir,
      chaptersDir: materialized.chaptersDir,
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.delete("/v1/books/:bookId/sessions/:id", async (req, res) => {
  try {
    const owner = bookSessionOwner();
    res.json(await bookSessions.close(owner, req.params.bookId, req.params.id));
  } catch (err) {
    sendError(res, err);
  }
});

app.put("/v1/voice/tts-voice", async (req, res) => {
  const voiceCfg = resolveVoiceConfig();
  const ttsVoice = resolveTtsVoiceId(voiceCfg, req.body?.ttsVoice);
  if (!ttsVoice) {
    res.status(400).json({ error: "ttsVoice is required" });
    return;
  }
  store.config.ttsVoice = ttsVoice;
  store.config[voiceMemoryKey(voiceStackOf(voiceCfg))] = ttsVoice;
  await store.save();
  res.json({ ttsVoice });
});

app.post("/v1/voice/tts-preview", async (req, res) => {
  try {
    const body = req.body && typeof req.body === "object" ? req.body : {};
    const voiceCfg = resolveVoiceConfig();
    const ttsVoice = resolveTtsVoiceId(voiceCfg, body.ttsVoice);
    if (!ttsVoice) {
      res.status(400).json({ error: "ttsVoice is required" });
      return;
    }
    const { pcm, sampleRate } = await synthesizeVoicePreview({
      ttsVoice,
      text: body.text,
      signal: requestSignal(req, res),
    });
    res.setHeader("Content-Type", "application/octet-stream");
    res.setHeader("X-Sample-Rate", String(sampleRate));
    res.send(pcm);
  } catch (err) {
    if (isCancelled(err)) {
      return;
    }
    sendError(res, err);
  }
});

app.post("/v1/client-logs", async (req, res) => {
  try {
    const body = req.body && typeof req.body === "object" ? req.body : {};
    const accepted = await appendClientLogs(store.config.workspaceRoot, body.entries, {
      app: body.app,
      platform: body.platform,
    });
    res.json({ accepted });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/diagnostics/probe", async (req, res) => {
  try {
    const body = req.body && typeof req.body === "object" ? req.body : {};
    const result = await runDiagnosticsProbe({
      workspaceRoot: store.config.workspaceRoot,
      ttsVoice:
        resolveTtsVoiceId(resolveVoiceConfig(), body.ttsVoice) ||
        resolveTtsVoiceId(resolveVoiceConfig(), store.config.ttsVoice),
      askCli: body.askCli !== false,
      askModel: body.askModel !== false,
      voiceTts: body.voiceTts !== false,
      voiceStt: body.voiceStt !== false,
      signal: requestSignal(req, res),
    });
    res.json(result);
  } catch (err) {
    sendError(res, err);
  }
});

app.put("/v1/settings/voice-stack", async (req, res) => {
  try {
    const stack = sanitizeVoiceStack(req.body?.stack ?? req.body?.voiceStack);
    if (!stack) {
      res.status(400).json({ error: "stack must be local, volc, or xiaomi" });
      return;
    }
    if (stack === "local") {
      await ensureFunasrAsrWorker(process.env);
      await ensureCosyVoiceTtsWorker(process.env);
    }
    const previousStack = store.config.voiceStack;
    const previousVoice = store.config.ttsVoice;
    const previousLocal = store.config.ttsVoiceLocal;
    const previousVolc = store.config.ttsVoiceVolc;
    const previousXiaomi = store.config.ttsVoiceXiaomi;
    const leaving = sanitizeVoiceStack(previousStack) || voiceStackOf(resolveVoiceConfig());
    const leavingKey = voiceMemoryKey(leaving || "volc");
    store.config[leavingKey] = previousVoice || store.config[leavingKey];
    store.config.voiceStack = stack;
    setPreferredVoiceStack(stack);
    const next = resolveVoiceConfig();
    const remembered = store.config[voiceMemoryKey(stack)];
    const ttsVoice = voiceAfterStackSwitch(next, remembered, previousVoice);
    store.config.ttsVoice = ttsVoice;
    store.config[voiceMemoryKey(stack)] = ttsVoice;
    try {
      await store.save();
    } catch (err) {
      store.config.voiceStack = previousStack;
      store.config.ttsVoice = previousVoice;
      store.config.ttsVoiceLocal = previousLocal;
      store.config.ttsVoiceVolc = previousVolc;
      store.config.ttsVoiceXiaomi = previousXiaomi;
      setPreferredVoiceStack(previousStack);
      throw err;
    }
    res.json({ stack, ...publicVoiceStatus(withTtsVoice(next, ttsVoice)) });
  } catch (err) {
    sendError(res, err);
  }
});

app.put("/v1/settings/ask-engine", async (req, res) => {
  try {
    const engine = sanitizeAcpEngine(req.body?.engine ?? req.body?.acpEngine);
    if (!engine) {
      res.status(400).json({ error: "engine must be claude or cursor" });
      return;
    }
    const scope = String(req.body?.scope || "").trim().toLowerCase();
    if (scope === "book") {
      store.config.acpEngineBook = engine;
    } else if (scope === "repo") {
      store.config.acpEngineRepo = engine;
      store.config.acpEngine = engine;
    } else {
      store.config.acpEngineBook = engine;
      store.config.acpEngineRepo = engine;
      store.config.acpEngine = engine;
    }
    syncAcpEngineConfig(store.config);
    await store.save();
    const resets = [];
    if (!scope || scope === "repo") resets.push(sessions.resetAllChannels());
    if (!scope || scope === "book") resets.push(bookSessions.resetAllChannels());
    await Promise.all(resets);
    const activeScope = scope === "book" ? "book" : "repo";
    const active = detectCursorEngine(activeScope);
    res.json({
      engine,
      scope: scope || "all",
      preferences: {
        book: store.config.acpEngineBook,
        repo: store.config.acpEngineRepo,
      },
      available: Boolean(active),
      activeEngine: active?.provider || active?.id || null,
      model: active?.model || null,
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/books/voice-turn", async (req, res) => {
  try {
    await handleBookVoiceTurn(req, res, { store, bookSessions });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/chat/voice-turn", async (req, res) => {
  try {
    await handleRepoVoiceTurn(req, res, {
      store,
      sessions,
      checkoutRepo: (owner, repo, signal) => checkoutRepo(owner, repo, signal, { fast: true }),
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/books/chat", async (req, res) => {
  let turn;
  let turnSessionId = "";
  try {
    const bookId = String(req.body?.bookId || "").trim();
    const message = String(req.body?.message || "").trim();
    const sessionId = String(req.body?.sessionId || "").trim();
    const chapter = String(req.body?.chapter || "").trim();
    const history = Array.isArray(req.body?.history) ? req.body.history : [];
    if (!bookId || !message) {
      res.status(400).json({ error: "bookId and message are required" });
      return;
    }
    const book = await resolveBook(store.config.workspaceRoot, bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const owner = bookSessionOwner();
    const session = bookSessions.resolveForChat(owner, bookId, sessionId);
    turn = beginChatTurn(session.id);
    turnSessionId = session.id;
    const signal = turn.signal;
    const acp = detectCursorEngine("book");
    if (!acp) {
      res.status(503).json({
        error: "问书需要本机 Claude Code 或 Cursor Agent（ACP）。请安装并登录所选助手。",
        code: "acp_unconfigured",
      });
      return;
    }
    openSse(res);
    res.on("error", () => {});
    const unwatched = trackUnwatched(res);
    writeSse(res, { type: "meta", sessionId: session.id, bookId: book.id, engine: "acp" });
    writeSse(res, { type: "status", phase: "connect" });
    writeSse(res, { type: "status", phase: "book" });
    if (signal.aborted) {
      res.end();
      return;
    }

    await bookSessions.warm(session, materialized.cacheDir).catch(() => {});
    const bookContext = await formatBookAcpContext(book, materialized);
    const local = bookLocalView(materialized, book);
    const progress = emptyBookProgress(book);
    writeSse(res, { type: "start", engine: "acp" });
    writeSse(res, {
      type: "meta",
      book: { id: book.id, title: book.title, author: book.author },
      cache: materialized.cacheDir,
      workspace: materialized.cacheDir,
      chaptersDir: materialized.chaptersDir,
      sessionId: session.id,
      model: acp.model || null,
    });
    writeSse(res, { type: "status", phase: "generate" });
    let finalEngine = "local-progress";
    let finalAnswer = "";
    let notified = false;
    for await (const event of streamAnswer({
      question: message,
      history,
      progress,
      context: bookContext,
      bookContext,
      local,
      session,
      sessions: bookSessions,
      buildPrompt: (opts) =>
        buildBookAcpPrompt({ ...opts, currentChapter: chapter || undefined }),
      synthesize: (opts) =>
        synthesizeBookAnswer({ ...opts, question: message, book, bookContext, local }),
      detectEngine: () => detectCursorEngine("book"),
      signal,
      workspaceRoot: store.config.workspaceRoot,
      bookId: book.id,
    })) {
      if (event.type === "notification") notified = true;
      if (event.type === "done") {
        finalEngine = event.engine;
        finalAnswer = event.answer || "";
        writeSseSafe(res, {
          type: "done",
          engine: finalEngine,
          model: acp.model || null,
          answer: finalAnswer,
          bookId: book.id,
          cache: materialized.cacheDir,
          sessionId: session.id,
        });
      } else {
        writeSseSafe(res, event);
      }
    }
    await notifyFinishedAnswer({
      notified,
      aborted: signal.aborted,
      unwatched: unwatched(),
      answer: finalAnswer,
      session,
      question: message,
      bookId: book.id,
    });
    if (signal.aborted) {
      try { res.end(); } catch { /* already gone */ }
      return;
    }
    if (!finalAnswer) {
      writeSseSafe(res, {
        type: "done",
        engine: finalEngine,
        answer: "",
        bookId: book.id,
        cache: materialized.cacheDir,
        sessionId: session.id,
      });
    }
    try { res.end(); } catch { /* already gone */ }
  } catch (err) {
    if (res.headersSent) {
      writeSseSafe(res, { type: "error", error: err.message });
      try { res.end(); } catch { /* already gone */ }
      return;
    }
    sendError(res, err);
  } finally {
    if (turn) endChatTurn(turnSessionId, turn);
  }
});

app.post("/v1/chat/cancel", async (req, res) => {
  const sessionId = String(req.body?.sessionId || "").trim();
  if (!sessionId) {
    res.status(400).json({ error: "sessionId is required" });
    return;
  }
  chatCancels.get(sessionId)?.abort();
  await sessions.cancelById(sessionId).catch(() => {});
  await bookSessions.cancelById(sessionId).catch(() => {});
  res.json({ ok: true });
});

app.post("/v1/chat", async (req, res) => {
  let turn;
  let turnSessionId = "";
  try {
    const owner = String(req.body?.owner || "").trim();
    const repo = String(req.body?.repo || "").trim();
    const message = String(req.body?.message || "").trim();
    const sessionId = String(req.body?.sessionId || "").trim();
    const history = Array.isArray(req.body?.history) ? req.body.history : [];
    const agentMode = req.body?.agentMode === true;
    if (!owner || !repo || !message) {
      res.status(400).json({ error: "owner, repo, and message are required" });
      return;
    }
    const session = sessions.resolveForChat(owner, repo, sessionId);
    turn = beginChatTurn(session.id);
    turnSessionId = session.id;
    const signal = turn.signal;
    openSse(res);
    res.on("error", () => {});
    const unwatched = trackUnwatched(res);
    writeSse(res, { type: "meta", sessionId: session.id });
    if (detectCursorEngine("repo")) {
      writeSse(res, { type: "start", engine: "acp" });
    }
    writeSse(res, { type: "status", phase: "repo" });
    const destGuess = checkoutPath(store.config.workspaceRoot, owner, repo);
    const present = isCheckoutPresent(store.config.workspaceRoot, owner, repo);
    const warmPromise =
      present && detectCursorEngine("repo")
        ? sessions.warmRepo(owner, repo, destGuess).catch(() => {})
        : Promise.resolve();
    let progress;
    let dest;
    let local;
    if (present) {
      const snapPromise = snapshotCheckoutLite(destGuess);
      const [, localSnap] = await Promise.all([warmPromise, snapPromise]);
      if (localSnap?.present) {
        dest = destGuess;
        local = localSnap;
        progress = emptyRepoProgress(owner, repo, local.branch || "main");
      } else {
        ({ progress, dest, local } = await checkoutRepo(owner, repo, signal, { fast: true }));
        if (detectCursorEngine("repo")) {
          await sessions.warmRepo(owner, repo, dest).catch(() => {});
        }
      }
    } else {
      ({ progress, dest, local } = await Promise.all([
        checkoutRepo(owner, repo, signal, { fast: true }),
        warmPromise,
      ]).then(([checkout]) => checkout));
      if (detectCursorEngine("repo")) {
        await sessions.warmRepo(owner, repo, dest).catch(() => {});
      }
    }
    if (signal.aborted) {
      res.end();
      return;
    }
    const localContext = formatLocalContext(local);
    const githubContext = formatAcpContext(local, progress);
    const context = `${formatProgressContext(progress)}\n\n${localContext}`;
    writeSse(res, {
      type: "meta",
      repo: progress.repo.fullName,
      checkout: dest,
      sessionId: session.id,
    });
    writeSse(res, { type: "status", phase: "generate" });
    let finalEngine = "local-progress";
    let finalAnswer = "";
    let notified = false;
    for await (const event of streamAnswer({
      question: message,
      history,
      progress,
      context,
      githubContext,
      local,
      session,
      sessions,
      signal,
      agentMode,
      staticFiles: staticFilesPrompt(store.config),
      workspaceRoot: store.config.workspaceRoot,
      detectEngine: () => detectCursorEngine("repo"),
    })) {
      if (event.type === "notification") notified = true;
      if (event.type === "done") {
        finalEngine = event.engine;
        finalAnswer = event.answer;
        writeSseSafe(res, {
          type: "done",
          engine: event.engine,
          answer: event.answer,
          repo: progress.repo.fullName,
          checkout: dest,
          sessionId: session.id,
        });
      } else {
        writeSseSafe(res, event);
      }
    }
    await notifyFinishedAnswer({
      notified,
      aborted: signal.aborted,
      unwatched: unwatched(),
      answer: finalAnswer,
      session,
      question: message,
    });
    if (signal.aborted) {
      try { res.end(); } catch { /* already gone */ }
      return;
    }
    if (!finalAnswer) {
      writeSseSafe(res, {
        type: "done",
        engine: finalEngine,
        answer: "",
        repo: progress.repo.fullName,
        checkout: dest,
        sessionId: session.id,
      });
    }
    try { res.end(); } catch { /* already gone */ }
  } catch (err) {
    if (res.headersSent) {
      writeSseSafe(res, { type: "error", error: err.message });
      try { res.end(); } catch { /* already gone */ }
      return;
    }
    sendError(res, err);
  } finally {
    if (turn) endChatTurn(turnSessionId, turn);
  }
});

app.get("/v1/tunnel", (_req, res) => {
  res.json(tunnel.status());
});

app.post("/v1/tunnel/start", (_req, res) => {
  try {
    res.json(tunnel.start());
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/tunnel/stop", (_req, res) => {
  res.json(tunnel.stop());
});

app.post("/v1/presence", (req, res) => {
  const state = String(req.body?.state || "").trim();
  if (state !== "foreground" && state !== "background") {
    res.status(400).json({ error: "state must be foreground or background" });
    return;
  }
  setPhoneForeground(state === "foreground");
  res.json({ ok: true, foreground: state === "foreground" });
});

app.get("/v1/inbox", async (_req, res) => {
  try {
    const items = await listInbox(store.config.workspaceRoot, { unreadOnly: false });
    res.json({ items });
    for (const it of items) {
      if (it && it.id && !it.read) await markInboxRead(store.config.workspaceRoot, it.id);
    }
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/inbox/:id/read", async (req, res) => {
  try {
    const changed = await markInboxRead(store.config.workspaceRoot, req.params.id);
    res.json({ ok: true, changed });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/inbox/clear", async (_req, res) => {
  try {
    await clearInbox(store.config.workspaceRoot);
    res.json({ ok: true });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/inbox", async (req, res) => {
  const body = req.body || {};
  const title = String(body.title || "").trim();
  const text = String(body.body || "").trim();
  if (!title || !text) {
    res.status(400).json({ error: "title and body are required" });
    return;
  }
  const kind = String(body.kind || "external-notification").slice(0, 64);
  const sessionId = body.sessionId ? String(body.sessionId).slice(0, 128) : undefined;
  const question = body.question ? String(body.question).slice(0, 200) : undefined;
  const answer = body.answer ? String(body.answer).slice(0, 20000) : undefined;
  const owner = body.owner ? String(body.owner).slice(0, 128) : undefined;
  const repo = body.repo ? String(body.repo).slice(0, 128) : undefined;
  const bookId = body.bookId ? String(body.bookId).slice(0, 128) : undefined;
  try {
    const item = await publishInboxNotice(store.config.workspaceRoot, {
      kind,
      title: title.slice(0, 128),
      body: text.slice(0, 280),
      answer,
      sessionId,
      question,
      owner,
      repo,
      bookId,
    });
    res.json({ ok: true, item });
  } catch (err) {
    sendError(res, err);
  }
});

const httpServer = createServer(app);

attachVoiceGateway(httpServer, {
  getApiKey: () => store.config.apiKey,
  checkoutRepo: (owner, repo, signal) => checkoutRepo(owner, repo, signal, { fast: true }),
  sessions,
});
attachSttGateway(httpServer, {
  getApiKey: () => store.config.apiKey,
});
attachNotifications(httpServer, {
  getStore: () => store,
});

function logCompanionStartup() {
  const lans = lanUrls(PORT);
  const callbacks = suggestedCallbackUrls({
    lanUrls: lans,
    tunnelUrl: store.config.publicUrl || tunnel.status().publicUrl,
  });
  console.log(`问象 companion listening on http://${BIND}:${PORT}`);
  console.log(`Public URL: ${store.config.publicUrl}`);
  console.log(`API key: ${store.config.apiKey}`);
  console.log(`Config: ${store.file}`);
  console.log(`Workspace: ${store.config.workspaceRoot}`);
  console.log(`Static files: ${staticDir(store.config.workspaceRoot)}`);
  if (lans.length) {
    console.log(`LAN: ${lans.join(", ")}`);
  }
  console.log(
    oauthReady()
      ? `GitHub OAuth ready. Register callback(s):\n  ${callbacks.join("\n  ")}`
      : "GitHub OAuth not configured — copy .env.example to .env at the repo root and fill GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET",
  );
  console.log(`Node executable: ${resolveNodeExecutable()}`);
  console.log(`Git executable: ${resolveGitExecutable()}`);
  const bookAcp = detectCursorEngine("book");
  const repoAcp = detectCursorEngine("repo");
  console.log(
    bookAcp
      ? `问书 Agent (${store.config.acpEngineBook}): ${bookAcp.id} (${bookAcp.path})`
      : `问书 Agent (${store.config.acpEngineBook}): not found`,
  );
  console.log(
    repoAcp
      ? `问象 Agent (${store.config.acpEngineRepo}): ${repoAcp.id} (${repoAcp.path})`
      : `问象 Agent (${store.config.acpEngineRepo}): not found — chat may use local checkout + GitHub adapter`,
  );
  const voice = publicVoiceStatus(resolveVoiceConfig());
  console.log(voice.ready ? "Voice STT: ready" : "Voice STT: 还没配语音密钥");
  console.log(
    voice.asrProvider === "funasr"
      ? "Voice ASR: FunASR (local, preloaded)"
      : voice.asrProvider === "xiaomi"
        ? "Voice ASR: Xiaomi MiMo"
        : "Voice ASR: Volcengine",
  );
  console.log(
    voice.ttsProvider === "cosyvoice"
      ? "Voice TTS: CosyVoice3 (local, preloaded)"
      : voice.ttsProvider === "xiaomi"
        ? "Voice TTS: Xiaomi MiMo"
        : "Voice TTS: Volcengine",
  );
  console.log(
    isVoiceCallEnabled()
      ? "Voice call (/v1/voice): enabled"
      : "Voice call (/v1/voice): disabled (set WENXIANG_VOICE_CALL_ENABLED=true to debug)",
  );
}

async function preloadVoiceWorkers() {
  const voiceCfg = resolveVoiceConfig();
  if (voiceCfg.asrProvider === "funasr") {
    console.log("Preloading FunASR worker (Paraformer)...");
    const layout = await ensureFunasrAsrWorker(process.env);
    const h = layout.health || {};
    console.log(
      `FunASR ready: device=${h.device || "?"} load_ms=${h.load_ms ?? "?"} @ ${layout.baseUrl}`,
    );
  }
  if (voiceCfg.ttsProvider === "cosyvoice") {
    console.log("Preloading CosyVoice TTS worker (Fun-CosyVoice3)...");
    const layout = await ensureCosyVoiceTtsWorker(process.env);
    const h = layout.health || {};
    console.log(
      `CosyVoice TTS ready: device=${h.device || "?"} load_ms=${h.load_ms ?? "?"} @ ${layout.baseUrl}`,
    );
  }
}

async function startCompanion() {
  await ensureStaticDir(store.config.workspaceRoot);
  const bound = await bindCompanion(httpServer, PORT, BIND);
  if (bound === "busy") {
    console.error(`问象已在端口 ${PORT} 运行，不再启动第二套。`);
    process.exit(COMPANION_ALREADY_RUNNING);
  }
  logCompanionStartup();
  tunnelHealth.start();
  await preloadVoiceWorkers();
}

startCompanion().catch((err) => {
  console.error(err);
  process.exit(1);
});

function shutdownVoiceWorkers() {
  shutdownFunasrAsrWorker();
  shutdownCosyVoiceTtsWorker();
}

process.on("SIGINT", () => shutdownVoiceWorkers());
process.on("SIGTERM", () => shutdownVoiceWorkers());
