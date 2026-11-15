/** FIFO readers/writer gate: reads can overlap, writes own the checkout. */
export function createWorkspaceGate() {
  const roots = new Map();
  return function acquire(root, { write = false, signal, onWaiting } = {}) {
    if (signal?.aborted) return Promise.reject(signal.reason || new Error('cancelled'));
    let state = roots.get(root);
    if (!state) roots.set(root, state = { readers: 0, writer: false, queue: [] });
    return new Promise((resolve, reject) => {
      const row = { write, start: null };
      const pump = () => {
        while (state.queue.length && !state.writer) {
          const next = state.queue[0];
          if (next.write && state.readers) break;
          state.queue.shift();
          next.start();
        }
        if (!state.writer && !state.readers && !state.queue.length) roots.delete(root);
      };
      const abort = () => {
        const at = state.queue.indexOf(row);
        if (at < 0) return;
        state.queue.splice(at, 1);
        signal?.removeEventListener('abort', abort);
        reject(signal.reason || new Error('cancelled'));
        pump();
      };
      row.start = () => {
        signal?.removeEventListener('abort', abort);
        if (write) state.writer = true;
        else state.readers++;
        let released = false;
        resolve(() => {
          if (released) return;
          released = true;
          if (write) state.writer = false;
          else state.readers--;
          pump();
        });
      };
      state.queue.push(row);
      signal?.addEventListener('abort', abort, { once: true });
      if (state.writer || (write && state.readers) || state.queue.length > 1) onWaiting?.();
      pump();
    });
  };
}
