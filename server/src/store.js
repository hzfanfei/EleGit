import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { defaultWorkspaceRoot } from "./workspace.js";

export function defaultHomeDir() {
  return process.env.WENXIANG_HOME || path.join(os.homedir(), ".wenxiang");
}

function defaultConfig() {
  return {
    apiKey: randomBytes(24).toString("hex"),
    githubToken: "",
    githubUser: null,
    githubClientId: process.env.GITHUB_CLIENT_ID || "",
    githubClientSecret: process.env.GITHUB_CLIENT_SECRET || "",
    workspaceRoot: defaultWorkspaceRoot(),
    tunnel: {
      provider: "cloudflare",
      bin: process.env.WENXIANG_TUNNEL_BIN || "cloudflared",
      customCommand: "",
    },
  };
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
    // Process env (including values loaded from server/.env) wins over config.json.
    if (process.env.GITHUB_CLIENT_ID) {
      config.githubClientId = process.env.GITHUB_CLIENT_ID;
    }
    if (process.env.GITHUB_CLIENT_SECRET) {
      config.githubClientSecret = process.env.GITHUB_CLIENT_SECRET;
    }
    if (process.env.WENXIANG_WORKSPACE) {
      config.workspaceRoot = process.env.WENXIANG_WORKSPACE;
    }
    if (!config.workspaceRoot) {
      config.workspaceRoot = defaultWorkspaceRoot();
    }
    if (!config.apiKey) {
      config.apiKey = defaultConfig().apiKey;
    }
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }
  await writeFile(file, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
  return {
    homeDir,
    file,
    config,
    async save() {
      await writeFile(file, `${JSON.stringify(this.config, null, 2)}\n`, {
        mode: 0o600,
      });
    },
  };
}
