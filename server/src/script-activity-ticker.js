import { execFileSync } from "node:child_process";
import { listInbox, patchInboxActivity } from "./inbox.js";
import { broadcastInboxItem } from "./notifications.js";
import { planScriptActivityUpdates, scriptRuns } from "./script-activity.js";

function listProcessCommandLines() {
  try {
    if (process.platform === "win32") {
      const out = execFileSync(
        "powershell",
        [
          "-NoProfile",
          "-Command",
          "Get-CimInstance Win32_Process | Select-Object -ExpandProperty CommandLine",
        ],
        { encoding: "utf8", windowsHide: true, timeout: 8000 },
      );
      return out.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
    }
    const out = execFileSync("ps", ["-ax", "-o", "command="], {
      encoding: "utf8",
      timeout: 4000,
    });
    return out.split("\n").map((line) => line.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * Keep a running script's elapsed time moving in the inbox after the
 * companion process that first published it has been killed. When the
 * command is gone, replace the frozen「已跑 N 秒」with「已结束」.
 */
export function startScriptActivityTicker({
  workspaceRoot,
  intervalMs = 2000,
  listCommands = listProcessCommandLines,
  patch = patchInboxActivity,
  broadcast = broadcastInboxItem,
} = {}) {
  if (!workspaceRoot) return () => {};
  const anchors = new Map();
  let running = false;
  let timer = null;

  async function tick() {
    if (running) return;
    running = true;
    try {
      const items = await listInbox(workspaceRoot);
      const interesting = items.some((item) => item?.partial && scriptRuns(item.activity || "").length);
      if (!interesting) return;
      const commands = await listCommands();
      const patches = planScriptActivityUpdates(items, { commands, now: Date.now(), anchors });
      for (const change of patches) {
        const next = await patch(workspaceRoot, change.id, change.expected, change.activity);
        if (next) broadcast(next);
      }
    } catch {
      // Inbox progress is best-effort.
    } finally {
      running = false;
    }
  }

  timer = setInterval(() => {
    void tick();
  }, intervalMs);
  timer.unref?.();
  void tick();
  return () => {
    if (timer) clearInterval(timer);
    timer = null;
  };
}
