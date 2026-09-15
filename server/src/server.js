import express from "express";
import cors from "cors";
import { answerQuestion, detectCursorEngine } from "./ask.js";
import {
  formatProgressContext,
  listRepos,
  pollDeviceFlow,
  repoProgress,
  startDeviceFlow,
  verifyToken,
} from "./github.js";
import { lanUrls } from "./network.js";
import { loadStore } from "./store.js";
import { createTunnelManager } from "./tunnel.js";

const PORT = Number(process.env.WENXIANG_PORT || 8787);
const BIND = process.env.WENXIANG_BIND || "0.0.0.0";

const store = await loadStore();
const tunnel = createTunnelManager({
  port: PORT,
  getConfig: () => store.config,
});

const app = express();
app.use(cors());
app.use(express.json({ limit: "1mb" }));

function sendError(res, err) {
  const status = err.status && Number.isInteger(err.status) ? err.status : 500;
  res.status(status).json({
    error: err.message || "Internal error",
    code: err.code || undefined,
  });
}

app.get("/health", (_req, res) => {
  res.json({ ok: true, name: "问象", service: "wenxiang" });
});

app.use("/v1", (req, res, next) => {
  const key = req.get("X-Wenxiang-Key") || "";
  if (!store.config.apiKey || key !== store.config.apiKey) {
    res.status(401).json({ error: "Missing or invalid X-Wenxiang-Key" });
    return;
  }
  next();
});

function requireGithub(req, res, next) {
  if (!store.config.githubToken) {
    res.status(401).json({ error: "GitHub is not connected. Save a PAT first." });
    return;
  }
  next();
}

app.get("/v1/status", (_req, res) => {
  const cursor = detectCursorEngine();
  res.json({
    name: "问象",
    github: {
      connected: Boolean(store.config.githubToken),
      user: store.config.githubUser,
      deviceFlowReady: Boolean(store.config.githubClientId),
    },
    cursor: {
      available: Boolean(cursor),
      engine: cursor?.id || null,
      fallback: "local-progress",
    },
    tunnel: tunnel.status(),
    lanUrls: lanUrls(PORT),
    port: PORT,
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

app.get("/v1/repos/:owner/:repo/progress", requireGithub, async (req, res) => {
  try {
    const progress = await repoProgress(
      store.config.githubToken,
      req.params.owner,
      req.params.repo,
    );
    res.json(progress);
  } catch (err) {
    sendError(res, err);
  }
});

app.post("/v1/chat", requireGithub, async (req, res) => {
  try {
    const owner = String(req.body?.owner || "").trim();
    const repo = String(req.body?.repo || "").trim();
    const message = String(req.body?.message || "").trim();
    const history = Array.isArray(req.body?.history) ? req.body.history : [];
    if (!owner || !repo || !message) {
      res.status(400).json({ error: "owner, repo, and message are required" });
      return;
    }
    const progress = await repoProgress(store.config.githubToken, owner, repo);
    const context = formatProgressContext(progress);
    const result = await answerQuestion({
      question: message,
      history,
      progress,
      context,
    });
    res.json({
      engine: result.engine,
      answer: result.answer,
      repo: progress.repo.fullName,
    });
  } catch (err) {
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
  console.log(`问象 companion listening on http://${BIND}:${PORT}`);
  console.log(`API key: ${store.config.apiKey}`);
  console.log(`Config: ${store.file}`);
  if (lans.length) {
    console.log(`LAN: ${lans.join(", ")}`);
  }
  const cursor = detectCursorEngine();
  console.log(
    cursor
      ? `Cursor engine: ${cursor.id} (${cursor.path})`
      : "Cursor engine: not found — chat will use local GitHub progress adapter",
  );
});
