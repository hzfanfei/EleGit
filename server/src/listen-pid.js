/** PIDs listening on `port`, parsed from `netstat -ano -p tcp` output. */
export function listeningPidsFromNetstat(text, port) {
  const want = Number(port);
  if (!Number.isInteger(want) || want <= 0) return [];
  const pids = [];
  const seen = new Set();
  for (const line of String(text || "").split(/\r?\n/)) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 5) continue;
    if (parts[0].toUpperCase() !== "TCP") continue;
    if (String(parts[3]).toUpperCase() !== "LISTENING") continue;
    if (localPort(parts[1]) !== want) continue;
    const pid = Number(parts[parts.length - 1]);
    if (!Number.isInteger(pid) || pid <= 0 || seen.has(pid)) continue;
    seen.add(pid);
    pids.push(pid);
  }
  return pids;
}

function localPort(address) {
  const text = String(address || "");
  const idx = text.lastIndexOf(":");
  if (idx < 0) return NaN;
  return Number(text.slice(idx + 1));
}
