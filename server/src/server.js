import express from "express";
import cors from "cors";
import { corsOptions } from "./cors.js";
import { loadLocalEnv } from "./env.js";
import { createSessionStore, detectCursorEngine } from "./acp.js";
import { streamAnswer } from "./ask.js";
import { openSse, writeSse } from "./sse.js";
import {
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
import { loadStore } from "./store.js";
import { createTunnelManager } from "./tunnel.js";
import { ensureCheckout, formatLocalContext } from "./workspace.js";

loadLocalEnv();

const PORT = Number(process.env.WENXIANG_PORT || 8787);
const BIND = process.env.WENXIANG_BIND || "0.0.0.0";

const store = await loadStore();
const sessions = createSessionStore();
const oauth = createOAuthSessions();
const tunnel = createTunnelManager({
  port: PORT,
  getConfig: () => store.config,
});

const app = express();
app.use(cors(corsOptions));
app.options("*", cors(corsOptions));
app.use(express.json({ limit: "1mb" }));

function sendError(res, err) {
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
  res.json({ ok: true, name: "问象", service: "wenxiang" });
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

function requireGithub(req, res, next) {
  if (!store.config.githubToken) {
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
      connected: Boolean(store.config.githubToken),
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
    },
    cursor: {
      available: Boolean(cursor),
      engine: cursor?.id || null,
      mode: cursor?.mode || null,
      transport: cursor?.transport || null,
      fallback: "local-progress",
    },
    tunnel: tunnelStatus,
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
    connected: session.status === "connected" && Boolean(store.config.githubToken),
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

app.get("/v1/repos", requireGithub, async (req, res) => {
  try {
    const repos = await listRepos(store.config.githubToken, String(req.query.q || ""));
    res.json({ repos });
  } catch (err) {
    sendError(res, err);
  }
});

async function checkoutRepo(owner, repo) {
  const progress = await repoProgress(store.config.githubToken, owner, repo);
  const result = await ensureCheckout({
    workspaceRoot: store.config.workspaceRoot,
    owner,
    repo,
    token: store.config.githubToken,
    defaultBranch: progress.repo.defaultBranch,
  });
  return { progress, ...result };
}

app.post("/v1/repos/:owner/:repo/checkout", requireGithub, async (req, res) => {
  try {
    const { progress, dest, existed, local } = await checkoutRepo(
      req.params.owner,
      req.params.repo,
    );
    res.json({
      path: dest,
      existed,
      local,
      repo: progress.repo,
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
    res.status(201).json(sessions.create(req.params.owner, req.params.repo));
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
    openSse(res);
    writeSse(res, { type: "meta", sessionId: session.id });
    const { progress, dest, local } = await checkoutRepo(owner, repo);
    const githubContext = formatProgressContext(progress);
    const context = `${githubContext}\n\n${formatLocalContext(local)}`;
    writeSse(res, {
      type: "meta",
      repo: progress.repo.fullName,
      checkout: dest,
      sessionId: session.id,
    });
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
    })) {
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

app.listen(PORT, BIND, () => {
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
  const cursor = detectCursorEngine();
  console.log(
    cursor
      ? `Cursor engine: ${cursor.id} (${cursor.path})`
      : "Cursor engine: not found — chat will use local checkout + GitHub adapter",
  );
});
