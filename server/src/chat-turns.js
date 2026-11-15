/** Match cancellation to a turn before touching a reusable ACP session. */
export function createChatTurns() {
  const active = new Map();
  return {
    begin(sessionId, turnId = '') {
      active.get(sessionId)?.abort();
      const turn = new AbortController();
      turn.turnId = turnId;
      active.set(sessionId, turn);
      return turn;
    },
    end(sessionId, turn) {
      if (active.get(sessionId) === turn) active.delete(sessionId);
    },
    async cancel(sessionId, turnId, cancelSession) {
      const turn = active.get(sessionId);
      if (!turn || turn.turnId !== turnId) return false;
      turn.abort();
      await cancelSession();
      return true;
    },
  };
}
