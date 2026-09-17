/** Compare slow vs fast checkout steps (same machine, no HTTP). */
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { repoProgress } from "../src/github.js";
import { ensureCheckout, getCheckoutSyncStatus, isCheckoutPresent } from "../src/workspace.js";

const home = process.env.WENXIANG_HOME || path.join(os.homedir(), ".wenxiang");
const cfg = JSON.parse(await readFile(path.join(home, "config.json"), "utf8"));
const owner = "hzfanfei";
const repo = "fwechat";
const token = cfg.githubToken;
const workspaceRoot = cfg.workspaceRoot || path.join(os.homedir(), "问象");

async function time(label, fn) {
  const t0 = performance.now();
  const result = await fn();
  const ms = performance.now() - t0;
  console.log(`${label}: ${ms.toFixed(0)}ms`);
  return { ms, result };
}

if (!isCheckoutPresent(workspaceRoot, owner, repo)) {
  console.error("Checkout missing — clone first");
  process.exit(1);
}

const gh = await time("repoProgress (4 GitHub API)", () => repoProgress(token, owner, repo));
const fetch = await time("git fetch only", () =>
  getCheckoutSyncStatus({
    workspaceRoot,
    owner,
    repo,
    defaultBranch: gh.result?.repo?.defaultBranch || "main",
    token,
    fetchRemote: true,
  }),
);
const noFetch = await time("sync status without fetch", () =>
  getCheckoutSyncStatus({
    workspaceRoot,
    owner,
    repo,
    defaultBranch: gh.result?.repo?.defaultBranch || "main",
    token: undefined,
    fetchRemote: false,
  }),
);
await time("ensureCheckout fetchRemote=false (snapshot only)", () =>
  ensureCheckout({
    workspaceRoot,
    owner,
    repo,
    token,
    defaultBranch: gh.result?.repo?.defaultBranch || "main",
    fetchRemote: false,
  }),
);
await time("ensureCheckout fetchRemote=true (old chat path)", () =>
  ensureCheckout({
    workspaceRoot,
    owner,
    repo,
    token,
    defaultBranch: gh.result?.repo?.defaultBranch || "main",
    fetchRemote: true,
  }),
);

const oldSequential = gh.ms + fetch.ms;
const fastParallel = Math.max(noFetch.ms, 0);
console.log("\n--- estimated chat prep before ACP (existing checkout) ---");
console.log(`Old (await GitHub + fetch):     ~${oldSequential.toFixed(0)}ms sequential`);
console.log(`New fast (skip GH wait + no fetch): ~${noFetch.ms.toFixed(0)}ms`);
