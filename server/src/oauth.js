import { randomBytes } from "node:crypto";

const GITHUB_AUTHORIZE = "https://github.com/login/oauth/authorize";
const GITHUB_TOKEN = "https://github.com/login/oauth/access_token";
const OAUTH_SCOPE = "repo read:user";
const STATE_TTL_MS = 15 * 60 * 1000;

export function normalizePublicBase(raw) {
  const text = String(raw || "").trim().replace(/\/+$/, "");
  if (!text) {
    const err = new Error("publicBaseUrl is required for browser OAuth");
    err.status = 400;
    throw err;
  }
  let url;
  try {
    url = new URL(text);
  } catch {
    const err = new Error("publicBaseUrl must be an absolute http(s) URL");
    err.status = 400;
    throw err;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    const err = new Error("publicBaseUrl must be http or https");
    err.status = 400;
    throw err;
  }
  return `${url.protocol}//${url.host}`;
}

export function callbackUrl(publicBaseUrl) {
  return `${normalizePublicBase(publicBaseUrl)}/oauth/github/callback`;
}

export function suggestedCallbackUrls({ lanUrls = [], tunnelUrl = "" } = {}) {
  const bases = new Set(["http://127.0.0.1:8787", ...lanUrls]);
  if (tunnelUrl) bases.add(String(tunnelUrl).replace(/\/+$/, ""));
  return [...bases].map((base) => `${base.replace(/\/+$/, "")}/oauth/github/callback`);
}

export function createOAuthSessions() {
  const pending = new Map();

  function sweep(now = Date.now()) {
    for (const [state, row] of pending) {
      if (now - row.createdAt > STATE_TTL_MS) pending.delete(state);
    }
  }

  function start({ clientId, publicBaseUrl }) {
    if (!clientId) {
      const err = new Error(
        "Browser login needs a GitHub OAuth App. Copy server/.env.example to server/.env and set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET, then register the callback URL.",
      );
      err.status = 400;
      throw err;
    }
    sweep();
    const redirectUri = callbackUrl(publicBaseUrl);
    const state = randomBytes(24).toString("hex");
    pending.set(state, {
      redirectUri,
      createdAt: Date.now(),
      status: "pending",
      error: "",
    });
    const authorize = new URL(GITHUB_AUTHORIZE);
    authorize.searchParams.set("client_id", clientId);
    authorize.searchParams.set("redirect_uri", redirectUri);
    authorize.searchParams.set("scope", OAUTH_SCOPE);
    authorize.searchParams.set("state", state);
    return {
      state,
      redirectUri,
      authorizeUrl: authorize.toString(),
    };
  }

  function peek(state) {
    sweep();
    return pending.get(state) || null;
  }

  function fail(state, message) {
    const row = pending.get(state);
    if (row) {
      row.status = "error";
      row.error = message;
    }
  }

  function complete(state) {
    const row = pending.get(state);
    if (row) {
      row.status = "connected";
      row.error = "";
    }
  }

  return { start, peek, fail, complete };
}

export async function exchangeCode({ clientId, clientSecret, code, redirectUri }) {
  if (!clientId || !clientSecret) {
    const err = new Error("GitHub OAuth App client secret is missing");
    err.status = 400;
    throw err;
  }
  const res = await fetch(GITHUB_TOKEN, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      client_id: clientId,
      client_secret: clientSecret,
      code,
      redirect_uri: redirectUri,
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || body.error || !body.access_token) {
    const err = new Error(body.error_description || body.error || `GitHub token exchange HTTP ${res.status}`);
    err.status = 400;
    throw err;
  }
  return body.access_token;
}

export function callbackHtml({ ok, message }) {
  const title = ok ? "问象已连接 GitHub" : "问象登录未完成";
  const hint = ok ? "可以回到问象应用。" : "请回到问象重试，或检查 OAuth 回调 URL 是否与手机里的服务地址一致。";
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>${title}</title>
  <style>
    body { font-family: sans-serif; background:#101418; color:#d7dee6; padding:32px; }
    h1 { color:#e4b15a; font-size:22px; }
    p { line-height:1.5; }
  </style>
</head>
<body>
  <h1>${title}</h1>
  <p>${message}</p>
  <p>${hint}</p>
</body>
</html>`;
}
