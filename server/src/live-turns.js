// In-flight chat text while the companion runs a turn. When the phone cannot
// see SSE (disconnect, background, planned restart), partial rows go to inbox
// so the client hold-poll path can show tool/thought progress. After detach,
// the turn relay continues the same inbox mirror.

const turns = new Map();
let handoff = false;

export function handoffActive() {
  return handoff;
}

export function beginHandoff() {
  handoff = true;
}

export function getLiveTurn(sessionId) {
  const id = String(sessionId || "").trim();
  return id ? turns.get(id) : undefined;
}

export function noteLiveTurn(snapshot) {
  const id = String(snapshot?.session?.id || "").trim();
  if (!id) return;
  const prev = turns.get(id) || {};
  turns.set(id, {
    session: snapshot.session,
    question: snapshot.question ?? prev.question ?? "",
    bookId: snapshot.bookId ?? prev.bookId,
    answer: snapshot.answer ?? prev.answer ?? "",
    activity: snapshot.activity ?? prev.activity ?? "",
  });
}

export function clearLiveTurn(sessionId) {
  turns.delete(String(sessionId || ""));
}

export function listLiveTurns() {
  return [...turns.values()];
}

export async function publishLiveTurnSnapshots(workspaceRoot, { noticeFor, publish } = {}) {
  if (!workspaceRoot || !noticeFor || !publish) return 0;
  let published = 0;
  for (const snap of listLiveTurns()) {
    const notice = noticeFor(snap.answer, {
      session: snap.session,
      question: snap.question,
      bookId: snap.bookId,
      partial: true,
      activity: snap.activity,
    });
    if (!notice) continue;
    await publish(workspaceRoot, notice);
    published += 1;
  }
  return published;
}

const DEFAULT_MIRROR_MS = 800;

/**
 * While isUnwatched() is true, mirror one session's live turn into inbox
 * (same payload as handoff snapshots). Used for hold polling on the phone.
 */
export function createUnwatchedInboxMirror({
  workspaceRoot,
  isUnwatched,
  noticeFor,
  publish,
  intervalMs = DEFAULT_MIRROR_MS,
} = {}) {
  const published = new Map();

  function schedule(sessionId) {
    const id = String(sessionId || "").trim();
    if (!id || !workspaceRoot || !noticeFor || !publish) return;
    if (typeof isUnwatched !== "function" || !isUnwatched()) return;
    const snap = getLiveTurn(id);
    if (!snap) return;
    const answer = String(snap.answer || "").trim();
    const activity = String(snap.activity || "").trim();
    if (!answer && !activity) return;

    let entry = published.get(id);
    if (!entry) {
      entry = { timer: null, lastPublishAt: 0, answer: "", activity: "" };
      published.set(id, entry);
    }
    if (entry.timer) return;

    const now = Date.now();
    const wait = entry.lastPublishAt
      ? Math.max(0, intervalMs - (now - entry.lastPublishAt))
      : 0;
    entry.timer = setTimeout(() => {
      entry.timer = null;
      void flush(id);
    }, wait);
    entry.timer.unref?.();
  }

  async function flush(id) {
    if (typeof isUnwatched !== "function" || !isUnwatched()) return;
    const snap = getLiveTurn(id);
    if (!snap) return;
    const answer = String(snap.answer || "").trim();
    const activity = String(snap.activity || "").trim();
    if (!answer && !activity) return;

    const entry = published.get(id) || { lastPublishAt: 0, answer: "", activity: "" };
    if (answer === entry.answer && activity === entry.activity) return;

    const notice = noticeFor(answer, {
      session: snap.session,
      question: snap.question,
      bookId: snap.bookId,
      partial: true,
      activity,
    });
    if (!notice) return;

    entry.lastPublishAt = Date.now();
    entry.answer = answer;
    entry.activity = activity;
    published.set(id, entry);
    try {
      await publish(workspaceRoot, notice);
    } catch {
      /* inbox is best-effort */
    }
  }

  function dispose() {
    for (const entry of published.values()) {
      if (entry.timer) clearTimeout(entry.timer);
    }
    published.clear();
  }

  return { schedule, dispose };
}
