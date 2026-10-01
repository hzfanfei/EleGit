const WAIT_LABEL = /^(跑着|已跑 \d+ 秒|已跑 \d+ 分 \d+ 秒)$/;

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

/** Running script rows inside one activity blob. */
export function scriptRuns(activity) {
  const blocks = String(activity || "").split(/\n\n/);
  const runs = [];
  blocks.forEach((block, blockIndex) => {
    const lines = block.split("\n");
    if (lines[0] !== "跑脚本" || lines.length < 2) return;
    const parts = lines[1].split(" · ");
    if (parts.length < 2) return;
    const wait = parts[parts.length - 1];
    if (!WAIT_LABEL.test(wait)) return;
    runs.push({
      blockIndex,
      command: parts[0],
      seconds: scriptWaitSeconds(wait),
    });
  });
  return runs;
}

export function commandProbe(command) {
  return String(command || "").replace(/…$/, "").trim();
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
    const probe = commandProbe(last.command);
    const alive = probe.length >= 8 && lines.some((line) => line.includes(probe));
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
