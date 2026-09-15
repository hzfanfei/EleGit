import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

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
