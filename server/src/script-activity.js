const WAIT_LABEL = /^(跑着|已跑 \d+ 秒|已跑 \d+ 分 \d+ 秒)$/;
const GENERIC_COMMAND = /^(node(?:\.exe)?|npm|npx|python(?:3)?(?:\.exe)?|powershell(?:\.exe)?|pwsh(?:\.exe)?|cmd(?:\.exe)?|bash|sh|flutter|dart|git|yarn|pnpm|bun|deno)$/i;

export function formatScriptWait(seconds) {
  const sec = Math.max(0, Math.floor(Number(seconds) || 0));
  if (sec < 1) return "跑着";
  if (sec < 60) return `已跑 ${sec} 秒`;
  return `已跑 ${Math.floor(sec / 60)} 分 ${sec % 60} 秒`;
}

export function scriptWaitSeconds(label) {
  const text = String(label || "");
  if (text === "跑着") return 0;
  const minutes = /^已跑 (\d+) 分 (\d+) 秒$/.exec(text);
  if (minutes) return Number(minutes[1]) * 60 + Number(minutes[2]);
  const seconds = /^已跑 (\d+) 秒$/.exec(text);
  if (seconds) return Number(seconds[1]);
  return null;
}

/** Running script rows inside one activity blob. Ended rows stay out. */
export function scriptRuns(activity) {
  const blocks = String(activity || "").split(/\n\n/);
  const runs = [];
  blocks.forEach((block, blockIndex) => {
    const row = scriptRow(block);
    if (!row || row.ended) return;
    runs.push({ blockIndex, command: row.command, seconds: row.seconds });
  });
  return runs;
}

/**
 * A relay pulse keeps rewriting「已跑 N 秒」after the ticker has already
 * closed that command. Put「已结束」back so the progress hint stops flipping.
 */
export function keepEndedScriptRows(prevActivity, nextActivity) {
  const ended = new Set();
  for (const block of String(prevActivity || "").split(/\n\n/)) {
    const row = scriptRow(block);
    if (row?.ended && row.command) ended.add(row.command);
  }
  if (!ended.size) return String(nextActivity || "");
  const blocks = String(nextActivity || "").split(/\n\n/);
  let changed = false;
  const next = blocks.map((block) => {
    const row = scriptRow(block);
    if (!row || row.ended || !ended.has(row.command)) return block;
    changed = true;
    return setScriptWait(block, 0, "已结束");
  });
  return changed ? next.join("\n\n") : String(nextActivity || "");
}

export function commandProbe(command) {
  return String(command || "").replace(/…$/, "").trim();
}

function normalizeCommandLine(text) {
  return String(text || "").replace(/\\/g, "/").replace(/\s+/g, " ").trim().toLowerCase();
}

/**
 * True when a process list still contains this script.
 * Windows command lines use a full exe path, so the visible
 * `node scripts/foo.mjs` label is matched by its script token.
 */
export function commandAlive(command, lines) {
  const probe = normalizeCommandLine(commandProbe(command));
  if (probe.length < 8) return false;
  const normalized = (lines || []).map(normalizeCommandLine).filter(Boolean);
  if (normalized.some((line) => line.includes(probe))) return true;
  const tokens = probe.split(" ").filter((token) => token.length >= 2);
  const specific = tokens.filter((token) => !GENERIC_COMMAND.test(token));
  if (!specific.length) return false;
  const generics = tokens.filter((token) => GENERIC_COMMAND.test(token));
  const shortOnly = specific.every((token) => token.length < 8);
  return normalized.some((line) => {
    if (!specific.every((token) => line.includes(token))) return false;
    if (!shortOnly || !generics.length) return true;
    return generics.some((token) => line.includes(token.replace(/\.exe$/, "")) || line.includes(token));
  });
}

function scriptRow(block) {
  const lines = String(block || "").split("\n");
  if (lines[0] !== "跑脚本" || lines.length < 2) return null;
  const parts = lines[1].split(" · ");
  if (parts.length < 2) return null;
  const wait = parts[parts.length - 1];
  if (wait !== "已结束" && !WAIT_LABEL.test(wait)) return null;
  return {
    command: parts[0],
    seconds: scriptWaitSeconds(wait) ?? 0,
    ended: wait === "已结束",
  };
}

export function setScriptWait(activity, blockIndex, waitLabel) {
  const blocks = String(activity || "").split(/\n\n/);
  if (!blocks[blockIndex]) return String(activity || "");
  const lines = blocks[blockIndex].split("\n");
  const parts = String(lines[1] || "").split(" · ");
  if (parts.length < 2) return String(activity || "");
  parts[parts.length - 1] = waitLabel;
  lines[1] = parts.join(" · ");
  blocks[blockIndex] = lines.join("\n");
  return blocks.join("\n\n");
}

/**
 * Decide inbox rewrites for script rows.
 * A live command keeps counting from the first time we saw its label.
 * Two misses in a row mean the process is gone, so the row stops at 已结束.
 */
export function planScriptActivityUpdates(items, { commands = [], now = Date.now(), anchors = new Map() } = {}) {
  const lines = commands.map((line) => String(line || ""));
  const patches = [];
  for (const item of items || []) {
    if (!item?.partial || !item.id) continue;
    const runs = scriptRuns(item.activity);
    if (!runs.length) continue;
    const last = runs[runs.length - 1];
    const alive = commandAlive(last.command, lines);
    let anchor = anchors.get(item.id);
    if (!anchor || anchor.command !== last.command) {
      anchor = {
        command: last.command,
        baseAt: now - last.seconds * 1000,
        misses: 0,
      };
      anchors.set(item.id, anchor);
    }
    if (!alive) {
      anchor.misses += 1;
      if (anchor.misses < 2) continue;
      anchors.delete(item.id);
      const activity = setScriptWait(item.activity, last.blockIndex, "已结束");
      if (activity !== item.activity) patches.push({ id: item.id, expected: item.activity, activity });
      continue;
    }
    anchor.misses = 0;
    if (last.seconds > Math.floor((now - anchor.baseAt) / 1000) + 1) {
      anchor.baseAt = now - last.seconds * 1000;
    }
    const show = Math.floor((now - anchor.baseAt) / 1000);
    if (show === last.seconds) continue;
    const activity = setScriptWait(item.activity, last.blockIndex, formatScriptWait(show));
    if (activity !== item.activity) patches.push({ id: item.id, expected: item.activity, activity });
  }
  return patches;
}
