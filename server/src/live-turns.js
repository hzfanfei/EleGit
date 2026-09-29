// In-flight chat text held by the companion. A planned restart publishes this
// before the process dies, so the phone can keep showing progress while the
// agent continues on the turn relay.

const turns = new Map();
let handoff = false;

export function handoffActive() {
  return handoff;
}

export function beginHandoff() {
  handoff = true;
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
