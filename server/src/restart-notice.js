import { appendInboxItem } from "./inbox.js";
import { defaultWorkspaceRoot } from "./workspace.js";

export const RESTART_NOTICE_KIND = "companion-restart";

export function restartNoticePayload({ reason, source, delayMs } = {}) {
  const why = String(reason || "服务即将重启").trim();
  const src = String(source || "问象").trim();
  let body = `${src}：${why}`;
  if (delayMs > 0) {
    body += `，约 ${Math.ceil(delayMs / 1000)} 秒后生效`;
  }
  return {
    kind: RESTART_NOTICE_KIND,
    title: "问象即将重启",
    body: body.slice(0, 280),
  };
}

/** Push while companion is still up (WebSocket + inbox). Falls back to file if HTTP fails. */
export async function publishRestartNoticeLive({
  baseUrl,
  apiKey,
  workspaceRoot,
  fetchImpl = fetch,
  ...opts
} = {}) {
  const payload = restartNoticePayload(opts);
  const url = String(baseUrl || "").replace(/\/+$/, "");
  const key = String(apiKey || "").trim();
  if (url && key) {
    try {
      const res = await fetchImpl(`${url}/v1/inbox`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Wenxiang-Key": key,
        },
        body: JSON.stringify(payload),
      });
      if (res.ok) return { via: "http", payload };
    } catch {
      /* fall through */
    }
  }
  const root = workspaceRoot || defaultWorkspaceRoot();
  await appendInboxItem(root, payload);
  return { via: "file", payload };
}

/** When companion is already down (keep-alive crash path). Phone sees it after the next boot. */
export async function queueRestartNoticeFile(workspaceRoot, opts = {}) {
  const payload = restartNoticePayload(opts);
  const root = workspaceRoot || defaultWorkspaceRoot();
  await appendInboxItem(root, payload);
  return payload;
}
