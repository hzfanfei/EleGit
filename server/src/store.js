import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { DEFAULT_PUBLIC_URL } from "./env.js";
import { defaultWorkspaceRoot } from "./workspace.js";

export function defaultHomeDir() {
  return process.env.WENXIANG_HOME || path.join(os.homedir(), ".wenxiang");
}

export function resolveGithubToken(config = {}, env = process.env) {
  const fromConfig = [config.githubToken, config.github_token, config.access_token, config.token]
    .map((value) => String(value || "").trim())
    .find(Boolean);
  if (fromConfig) return fromConfig;
  const fromEnv = [env.GITHUB_TOKEN, env.GH_TOKEN, env.GITHUB_PAT]
    .map((value) => String(value || "").trim())
    .find(Boolean);
  return fromEnv || "";
}

function defaultConfig() {
  return {
    apiKey: process.env.WENXIANG_API_KEY || randomBytes(24).toString("hex"),
    githubToken: "",
    githubUser: null,
    githubClientId: process.env.GITHUB_CLIENT_ID || "",
    githubClientSecret: process.env.GITHUB_CLIENT_SECRET || "",
    workspaceRoot: defaultWorkspaceRoot(),
    publicUrl: DEFAULT_PUBLIC_URL,
    staticToken: "",
    tunnel: {
      provider: "cloudflare",
      bin: process.env.WENXIANG_TUNNEL_BIN || "cloudflared",
      customCommand: "",
    },
  };
}

function applyEnv(config) {
  if (process.env.GITHUB_CLIENT_ID) {
    config.githubClientId = process.env.GITHUB_CLIENT_ID;
  }
  if (process.env.GITHUB_CLIENT_SECRET) {
    config.githubClientSecret = process.env.GITHUB_CLIENT_SECRET;
  }
  if (process.env.WENXIANG_WORKSPACE) {
    config.workspaceRoot = process.env.WENXIANG_WORKSPACE;
  }
  if (process.env.WENXIANG_API_KEY) {
    config.apiKey = process.env.WENXIANG_API_KEY;
  }
  if (process.env.WENXIANG_PUBLIC_URL) {
    config.publicUrl = process.env.WENXIANG_PUBLIC_URL.replace(/\/+$/, "");
  }
  if (!config.workspaceRoot) {
    config.workspaceRoot = defaultWorkspaceRoot();
  }
  if (!config.publicUrl) {
    config.publicUrl = DEFAULT_PUBLIC_URL;
  }
  if (!config.apiKey) {
    config.apiKey = randomBytes(24).toString("hex");
  }
  if (process.env.WENXIANG_STATIC_TOKEN) {
    config.staticToken = process.env.WENXIANG_STATIC_TOKEN;
  }
  if (!config.staticToken) {
    config.staticToken = randomBytes(24).toString("hex");
  }
  return config;
}

export async function loadStore(homeDir = defaultHomeDir()) {
  await mkdir(homeDir, { recursive: true });
  const file = path.join(homeDir, "config.json");
  let config = defaultConfig();
  try {
    const raw = await readFile(file, "utf8");
    const parsed = JSON.parse(raw);
    config = {
      ...config,
      ...parsed,
      tunnel: { ...config.tunnel, ...(parsed.tunnel || {}) },
    };
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }
  applyEnv(config);
  const token = resolveGithubToken(config);
  if (token) config.githubToken = token;
  await writeFile(file, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  return {
    homeDir,
    file,
    config,
    async save() {
      applyEnv(this.config);
      await writeFile(file, `${JSON.stringify(this.config, null, 2)}\n`, {
        mode: 0o600,
      });
    },
  };
}
