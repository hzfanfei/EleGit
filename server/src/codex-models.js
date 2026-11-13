import { spawn } from "node:child_process";
import readline from "node:readline";
import { resolveCodexExecutable } from "./acp.js";

// Each refresh starts a new app-server so its catalog is read again.
export function listCodexModels({ executable = resolveCodexExecutable(), timeoutMs = 30000 } = {}) {
  if (!executable) return Promise.reject(new Error("未找到本机 Codex"));
  return new Promise((resolve, reject) => {
    const child = spawn(executable, ["app-server"], { windowsHide: true, stdio: ["pipe", "pipe", "pipe"] });
    const lines = readline.createInterface({ input: child.stdout });
    let done = false;
    const models = [];
    const finish = (error) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      lines.close();
      child.stdin.destroy();
      child.kill();
      if (error) reject(error);
      else resolve([...new Map(models.map(m => [m.id, m])).values()]);
    };
    const send = (id, method, params) => child.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    const timer = setTimeout(() => finish(new Error("获取 Codex 模型超时")), timeoutMs);
    child.on("error", finish);
    child.stdin.on("error", finish);
    child.stderr.resume();
    child.on("exit", () => finish(new Error("Codex 在返回模型列表前退出")));
    lines.on("line", line => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.id !== 1 && message.id !== 2) return;
      if (message.error) return finish(new Error(message.error.message || "获取 Codex 模型失败"));
      if (message.id === 1) {
        child.stdin.write(JSON.stringify({ method: "initialized" }) + "\n");
        send(2, "model/list", { limit: 100 });
      } else {
        for (const m of message.result?.data || []) {
          if (m.hidden || !m.model) continue;
          models.push({ id: m.model, label: m.displayName || m.model, reasoningEfforts: (m.supportedReasoningEfforts || []).map(e => e.reasoningEffort), defaultReasoningEffort: m.defaultReasoningEffort, supportsFast: (m.additionalSpeedTiers || []).includes("fast") });
        }
        if (message.result?.nextCursor) send(2, "model/list", { limit: 100, cursor: message.result.nextCursor });
        else finish();
      }
    });
    send(1, "initialize", { clientInfo: { name: "wenxiang", version: "0.1.0" } });
  });
}
