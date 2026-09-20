import { createServer } from "node:http";
import express from "express";
import cors from "cors";
import { corsOptions } from "./cors.js";
import { loadLocalEnv } from "./env.js";
import {
  applyAcpEnginePreference,
  buildBookAcpPrompt,
  createSessionStore,
  detectCursorEngine,
  sanitizeAcpEngine,
} from "./acp.js";
import { handleBookVoiceTurn } from "./book-voice-turn.js";
import { handleRepoVoiceTurn } from "./repo-voice-turn.js";
import { streamAnswer, synthesizeBookAnswer } from "./ask.js";
import { openSse, writeSse } from "./sse.js";
import {
  emptyRepoProgress,
  formatProgressContext,
  listRepos,
  pollDeviceFlow,
  repoProgress,
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
  withTtsVoice,
} from "./voice-config.js";
import { ensureCosyVoiceTtsWorker, shutdownCosyVoiceTtsWorker } from "./cosyvoice-tts.js";
import { ensureFunasrAsrWorker, shutdownFunasrAsrWorker } from "./funasr-asr.js";
import { attachSttGateway } from "./voice-stt-ws.js";
import { attachVoiceGateway, isVoiceCallEnabled } from "./voice-ws.js";
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

loadLocalEnv();
process.env = envWithNodeOnPath(process.env);

const PORT = Number(process.env.WENXIANG_PORT || 8787);
const BIND = process.env.WENXIANG_BIND || "0.0.0.0";

const store = await loadStore();
const savedAcpEngine =
  sanitizeAcpEngine(store.config.acpEngine) ||
  sanitizeAcpEngine(process.env.WENXIANG_ACP_ENGINE) ||
  "claude";
store.config.acpEngine = savedAcpEngine;
applyAcpEnginePreference(savedAcpEngine);

const sessions = createSessionStore();
const bookSessions = createSessionStore();
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
  const cursor = detectCursorEngine();
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
    },
    cursor: {
      available: Boolean(cursor),
      engine: cursor?.id || null,
      mode: cursor?.mode || null,
      model: cursor?.model || null,
      transport: cursor?.transport || null,
      preference: store.config.acpEngine || "claude",
      fallback: "local-progress",
    },
    voice: publicVoiceStatus(withTtsVoice(resolveVoiceConfig(), store.config.ttsVoice)),
    books: (() => {
      const acp = detectCursorEngine();
      return {
        engine: "acp",
        ready: Boolean(acp),
        model: acp?.model || null,
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
  if (!githubToken()) {
    return "main";
  }
  const progress = await repoProgress(githubToken(), owner, repo);
  return progress.repo.defaultBranch || "main";
}

async function checkoutRepo(owner, repo, signal, { fast = false } = {}) {
  const present = isCheckoutPresent(store.config.workspaceRoot, owner, repo);
  const dest = checkoutPath(store.config.workspaceRoot, owner, repo);
  let progress = null;
  let progressTask = null;

  if (githubToken()) {
    if (fast && present) {
      const branchHint = await detectDefaultBranch(dest).catch(() => "main");
      progress = emptyRepoProgress(owner, repo, branchHint);
      progressTask = repoProgress(githubToken(), owner, repo).catch(() => null);
    } else {
      progress = await repoProgress(githubToken(), owner, repo);
    }
  } else if (!present) {
    const err = new Error("尚未登录 GitHub，无法首次克隆。请先在浏览器里登录。");
    err.status = 401;
    err.code = "github_required";
    throw err;
  }

  const defaultBranch =
    progress?.repo?.defaultBranch || (present ? await resolveDefaultBranch(owner, repo) : "main");
  const canFetchRemote = Boolean(githubToken());
  const result = await ensureCheckout({
    workspaceRoot: store.config.workspaceRoot,
    owner,
    repo,
    token: githubToken(),
    defaultBranch,
    fetchRemote: canFetchRemote && !(fast && present),
    signal,
  });

  if (!progress) {
    progress = emptyRepoProgress(owner, repo, defaultBranch);
  }
  if (progressTask) {
    progressTask
      .then((full) => {
        if (full) Object.assign(progress, full);
      })
      .catch(() => {});
  }
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
      fetchRemote: req.query.fetch !== "0" && Boolean(githubToken()),
    });
    res.json(status);
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/repos/:owner/:repo/checkout", async (req, res) => {
  try {
    const { owner, repo } = req.params;
    if (!isCheckoutPresent(store.config.workspaceRoot, owner, repo) && !githubToken()) {
      res.status(401).json({
        error: "尚未登录 GitHub，无法首次克隆。请先在浏览器里登录。",
        code: "github_required",
      });
      return;
    }
    const { progress, dest, existed, local } = await checkoutRepo(
      owner,
      repo,
      requestSignal(req, res),
    );
    if (detectCursorEngine()) {
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

app.get("/v1/repos/:owner/:repo/progress", requireGithub, async (req, res) => {
  try {
    const { progress, dest, local } = await checkoutRepo(req.params.owner, req.params.repo);
    res.json({ ...progress, checkout: { path: dest, ...local } });
  } catch (err) {
    sendError(res, err);
  }
});

app.get("/v1/repos/:owner/:repo/sessions", requireGithub, (req, res) => {
  try {
    res.json(sessions.list(req.params.owner, req.params.repo));
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/repos/:owner/:repo/sessions", requireGithub, (req, res) => {
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

app.post("/v1/repos/:owner/:repo/sessions/warm", requireGithub, async (req, res) => {
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

app.delete("/v1/repos/:owner/:repo/sessions/:id", requireGithub, async (req, res) => {
  try {
    res.json(await sessions.close(req.params.owner, req.params.repo, req.params.id));
  } catch (err) {
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
    if (!detectCursorEngine()) {
      res.status(503).json({
        error: "问书需要本机 Cursor Agent（ACP）。请安装 agent 并 login。",
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

app.put("/v1/settings/ask-engine", async (req, res) => {
  const engine = sanitizeAcpEngine(req.body?.engine ?? req.body?.acpEngine);
  if (!engine) {
    res.status(400).json({ error: "engine must be claude or cursor" });
    return;
  }
  store.config.acpEngine = engine;
  applyAcpEnginePreference(engine);
  await store.save();
  await Promise.all([sessions.resetAllChannels(), bookSessions.resetAllChannels()]);
  const active = detectCursorEngine();
  res.json({
    engine,
    available: Boolean(active),
    activeEngine: active?.id || null,
  });
});

app.post("/v1/books/voice-turn", async (req, res) => {
  try {
    await handleBookVoiceTurn(req, res, { store, bookSessions });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/chat/voice-turn", requireGithub, async (req, res) => {
  try {
    await handleRepoVoiceTurn(req, res, {
      store,
      sessions,
      checkoutRepo: (owner, repo, signal) => checkoutRepo(owner, repo, signal, { fast: true }),
      githubToken,
    });
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/books/chat", async (req, res) => {
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
    const signal = requestSignal(req, res);
    req.on("close", () => {
      bookSessions.cancel?.(session).catch(() => {});
    });
    const acp = detectCursorEngine();
    if (!acp) {
      res.status(503).json({
        error: "问书需要本机 Cursor Agent（ACP）。请安装 agent 并 login。",
        code: "acp_unconfigured",
      });
      return;
    }
    openSse(res);
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
      signal,
    })) {
      if (signal.aborted) break;
      if (event.type === "done") {
        finalEngine = event.engine;
        finalAnswer = event.answer || "";
        writeSse(res, {
          type: "done",
          engine: finalEngine,
          model: acp.model || null,
          answer: finalAnswer,
          bookId: book.id,
          cache: materialized.cacheDir,
          sessionId: session.id,
        });
      } else {
        writeSse(res, event);
      }
    }
    if (signal.aborted) {
      res.end();
      return;
    }
    if (!finalAnswer) {
      writeSse(res, {
        type: "done",
        engine: finalEngine,
        answer: "",
        bookId: book.id,
        cache: materialized.cacheDir,
        sessionId: session.id,
      });
    }
    res.end();
  } catch (err) {
    if (res.headersSent) {
      writeSse(res, { type: "error", error: err.message });
      res.end();
      return;
    }
    sendError(res, err);
  }
});

app.post("/v1/chat", requireGithub, async (req, res) => {
  try {
    const owner = String(req.body?.owner || "").trim();
    const repo = String(req.body?.repo || "").trim();
    const message = String(req.body?.message || "").trim();
    const sessionId = String(req.body?.sessionId || "").trim();
    const history = Array.isArray(req.body?.history) ? req.body.history : [];
    if (!owner || !repo || !message) {
      res.status(400).json({ error: "owner, repo, and message are required" });
      return;
    }
    const session = sessions.resolveForChat(owner, repo, sessionId);
    const signal = requestSignal(req, res);
    req.on("close", () => {
      sessions.cancel?.(session).catch(() => {});
    });
    openSse(res);
    writeSse(res, { type: "meta", sessionId: session.id });
    if (detectCursorEngine()) {
      writeSse(res, { type: "start", engine: "acp" });
    }
    writeSse(res, { type: "status", phase: "repo" });
    const destGuess = checkoutPath(store.config.workspaceRoot, owner, repo);
    const present = isCheckoutPresent(store.config.workspaceRoot, owner, repo);
    const warmPromise =
      present && detectCursorEngine()
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
        if (githubToken()) {
          repoProgress(githubToken(), owner, repo)
            .then((full) => {
              if (full) Object.assign(progress, full);
            })
            .catch(() => {});
        }
      } else {
        ({ progress, dest, local } = await checkoutRepo(owner, repo, signal, { fast: true }));
        if (detectCursorEngine()) {
          await sessions.warmRepo(owner, repo, dest).catch(() => {});
        }
      }
    } else {
      ({ progress, dest, local } = await Promise.all([
        checkoutRepo(owner, repo, signal, { fast: true }),
        warmPromise,
      ]).then(([checkout]) => checkout));
      if (detectCursorEngine()) {
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
    })) {
      if (signal.aborted) break;
      if (event.type === "done") {
        finalEngine = event.engine;
        finalAnswer = event.answer;
        writeSse(res, {
          type: "done",
          engine: event.engine,
          answer: event.answer,
          repo: progress.repo.fullName,
          checkout: dest,
          sessionId: session.id,
        });
      } else {
        writeSse(res, event);
      }
    }
    if (signal.aborted) {
      res.end();
      return;
    }
    if (!finalAnswer) {
      writeSse(res, {
        type: "done",
        engine: finalEngine,
        answer: "",
        repo: progress.repo.fullName,
        checkout: dest,
        sessionId: session.id,
      });
    }
    res.end();
  } catch (err) {
    if (res.headersSent) {
      writeSse(res, { type: "error", error: err.message });
      res.end();
      return;
    }
    sendError(res, err);
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

const httpServer = createServer(app);

attachVoiceGateway(httpServer, {
  getApiKey: () => store.config.apiKey,
  checkoutRepo: (owner, repo, signal) => checkoutRepo(owner, repo, signal, { fast: true }),
  sessions,
});
attachSttGateway(httpServer, {
  getApiKey: () => store.config.apiKey,
});

async function startCompanion() {
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

  httpServer.listen(PORT, BIND, () => {
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
  const cursor = detectCursorEngine();
  console.log(
    cursor
      ? `Cursor engine: ${cursor.id} (${cursor.path})`
      : "Cursor engine: not found — chat will use local checkout + GitHub adapter",
  );
  const voice = publicVoiceStatus(resolveVoiceConfig());
  console.log(voice.ready ? "Voice STT: ready" : "Voice STT: 还没配语音密钥");
  console.log(
    voice.asrProvider === "funasr"
      ? "Voice ASR: FunASR (local, preloaded)"
      : "Voice ASR: Volcengine",
  );
  console.log(
    voice.ttsProvider === "cosyvoice"
      ? "Voice TTS: CosyVoice3 (local, preloaded)"
      : "Voice TTS: Volcengine",
  );
  console.log(
    isVoiceCallEnabled()
      ? "Voice call (/v1/voice): enabled"
      : "Voice call (/v1/voice): disabled (set WENXIANG_VOICE_CALL_ENABLED=true to debug)",
  );
  tunnelHealth.start();
  });
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
