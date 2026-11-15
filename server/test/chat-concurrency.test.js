import assert from 'node:assert/strict';
import { it } from 'node:test';
import { createWorkspaceGate } from '../src/workspace-gate.js';
import { createChatTurns } from '../src/chat-turns.js';
import { createSessionStore } from '../src/acp.js';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

it('coordinates real ACP prompts from separate sessions in the same checkout', async () => {
  let spawns = 0;
  const store = createSessionStore({
    resolveCommand: () => ({
      path: process.execPath,
      args: [fileURLToPath(new URL('./fixtures/fake-acp.js', import.meta.url))],
      transport: 'stdio',
    }),
    spawnImpl: (file, args, opts) => {
      spawns++;
      return spawn(file, args, { ...opts, env: {
        ...opts.env, FAKE_ACP_PROGRESS: 'text', FAKE_ACP_PROGRESS_GAP_MS: '25',
      } });
    },
  });
  const read = store.create('o', 'r');
  const write = store.create('o', 'r');
  let started;
  const firstActivity = new Promise(resolve => { started = resolve; });
  let readFinished = false;
  try {
    const first = store.prompt(read, {
      cwd: process.cwd(), question: 'read', history: [],
      onActivity: started, onDelta: () => {},
    }).then(() => { readFinished = true; });
    await firstActivity;
    const second = store.prompt(write, {
      cwd: process.cwd(), question: 'write', history: [], agentMode: true,
      buildPrompt: () => {
        assert.equal(readFinished, true);
        return 'write';
      },
      onDelta: () => {},
    });
    assert.equal(spawns, 1);
    await Promise.all([first, second]);
    assert.equal(spawns, 2);
  } finally {
    await store.close('o', 'r', read.id);
    await store.close('o', 'r', write.id);
  }
});

it('restores distinct phone session IDs after restart without sharing context', () => {
  const store = createSessionStore({ resolveCommand: () => null });
  const a = store.resolveForChat('o', 'r', 'old-phone-a');
  const b = store.resolveForChat('o', 'r', 'old-phone-b');
  assert.equal(a.id, 'old-phone-a');
  assert.equal(b.id, 'old-phone-b');
  assert.notEqual(a, b);
  assert.equal(store.resolveForChat('o', 'r', a.id), a);
  assert.throws(() => store.resolveForChat('o', 'other', a.id), { status: 409 });
});

it('allows parallel reads but gives queued writes exclusive checkout access', async () => {
  const acquire = createWorkspaceGate();
  const a = await acquire('repo');
  const b = await acquire('repo');
  const events = [];
  const writer = acquire('repo', { write: true }).then(release => {
    events.push('write');
    return release;
  });
  const reader = acquire('repo').then(release => {
    events.push('read');
    return release;
  });
  const other = await acquire('other', { write: true });
  other();
  a();
  await Promise.resolve();
  assert.deepEqual(events, []);
  b();
  const releaseWriter = await writer;
  assert.deepEqual(events, ['write']);
  releaseWriter();
  const releaseReader = await reader;
  assert.deepEqual(events, ['write', 'read']);
  releaseReader();
  releaseReader(); // Releasing twice cannot unlock a later owner.
});

it('removes cancelled waiters without starting them or blocking later tasks', async () => {
  const acquire = createWorkspaceGate();
  const release = await acquire('repo', { write: true });
  const cancelled = new AbortController();
  const waiting = acquire('repo', { write: true, signal: cancelled.signal });
  cancelled.abort();
  await assert.rejects(waiting);
  const next = acquire('repo', { write: true });
  release();
  (await next)();
});

it('ignores delayed cancellation of an old turn and cancellation after completion', async () => {
  const turns = createChatTurns();
  const old = turns.begin('s', 'old');
  turns.end('s', old);
  const next = turns.begin('s', 'new');
  let cancels = 0;
  const cancel = () => { cancels++; };
  assert.equal(await turns.cancel('s', 'old', cancel), false);
  assert.equal(await turns.cancel('s', '', cancel), false);
  assert.equal(next.signal.aborted, false);
  assert.equal(await turns.cancel('s', 'new', cancel), true);
  assert.equal(next.signal.aborted, true);
  assert.equal(cancels, 1);
  turns.end('s', next);
  assert.equal(await turns.cancel('s', 'new', cancel), false);
});
