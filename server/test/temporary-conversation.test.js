import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { TemporaryConversation } from '../src/temporary-conversation.js';
import { createTemporaryChats } from '../src/temporary-chat.js';
import { attachTemporaryDownloads, attachTemporaryRoutes } from '../src/temporary-chat-routes.js';
import { createVoiceSession } from '../src/voice-session.js';
import { listStaticFiles, resolveStaticFile } from '../src/static-files.js';

const tick = () => new Promise(resolve => setImmediate(resolve));

test('temporary voice HTTP marks audio packets for the shared phone player', async () => {
  const chat = fakeChat(); const c = new TemporaryConversation(chat);
  const app = express(); app.use(express.json());
  attachTemporaryRoutes(app, { get: () => c }, {
    resolveConfig: () => ({ ready: true, provider: 'volc', volc: { ttsFormat: 'pcm' } }),
    createProviders: () => ({ tts: async () => Buffer.from([0, 1, 0, 2]) }),
  });
  const server = await new Promise(resolve => { const srv = app.listen(0, '127.0.0.1', () => resolve(srv)); });
  try {
    const result = await fetch(`http://127.0.0.1:${server.address().port}/v1/temporary-chats/test/voice-turn`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ message: '测试语音' }),
    });
    chat.replies[0].resolve();
    const events = (await result.text()).split('\n').filter(l => l.startsWith('data:')).map(l => JSON.parse(l.slice(5)));
    assert(events.some(e => e.type === 'audio' && e.pcm));
    assert(events.some(e => e.type === 'state' && e.phase === 'speak'));
    assert.equal(events.at(-1).engine, 'codex');
  } finally { await c.close(); await new Promise(resolve => server.close(resolve)); }
});

test('temporary voice identifies the engine and never starts an already cancelled turn', async () => {
  const chat = fakeChat(); const c = new TemporaryConversation(chat);
  try {
    const aborted = new AbortController(); aborted.abort();
    for await (const _ of c.voice('不应运行', aborted.signal)) assert.fail('cancelled turn emitted data');
    assert.equal(c.turns.length, 0);
    const stream = c.voice('语音问题', new AbortController().signal);
    assert.deepEqual((await stream.next()).value, { type: 'start', engine: 'codex' });
    chat.replies[0].resolve(); await tick();
    const output = []; for await (const event of stream) output.push(event);
    assert.equal(output.at(-1).engine, 'codex'); assert.equal(output.at(-1).text, '回答');
  } finally { await c.close(); }
});

test('completion is published only after generated files are ready', async () => {
  const chat = fakeChat(); const c = new TemporaryConversation(chat);
  let release;
  const scan = new Promise(resolve => { release = resolve; });
  c.scanFiles = async () => { await scan; c.files = [{ path: 'outputs/result.txt', size: 1 }]; };
  try {
    c.submit({ id: 'a', message: '生成文件' }); chat.replies[0].resolve(); await tick();
    assert.equal(c.snapshot().busy, true); assert.equal(c.snapshot().turns[0].status, 'running');
    release(); await tick();
    assert.equal(c.snapshot().turns[0].status, 'completed'); assert.equal(c.snapshot().files[0].path, 'outputs/result.txt');
  } finally { release(); await c.close(); }
});

test('a delayed stop for the previous question never stops the next one', async () => {
  const chat = fakeChat(); const c = new TemporaryConversation(chat);
  try {
    c.submit({ id: 'old', message: '第一问' }); chat.replies[0].resolve(); await tick();
    c.submit({ id: 'new', message: '第二问' });
    await c.stop('old'); await tick(); assert.equal(c.current.id, 'new'); assert.equal(c.current.status, 'running');
    await c.stop('new'); await tick(); assert.equal(c.turns[1].status, 'stopped');
  } finally { await c.close(); }
});
function fakeChat() {
  return {
    calls: [], contexts: [], replies: [],
    async prompt(text, onDelta, model, images, onStatus, options) {
      this.calls.push({ text, model, images, options }); this.threadId = 'fake';
      onStatus('正在执行命令');
      options.onEvent('item/started', { item: { id: 'command', type: 'commandExecution', command: 'echo hi' } });
      options.onEvent('item/commandExecution/outputDelta', { itemId: 'command', delta: 'hi' });
      await new Promise((resolve, reject) => this.replies.push({ resolve: () => { onDelta('回答'); resolve(); }, reject }));
      options.onEvent('item/completed', { item: { id: 'command', type: 'commandExecution', exitCode: 0 } });
    },
    async interrupt() { this.replies.at(-1)?.reject(new Error('已停止')); },
    async openThread(history) { this.contexts.push(history); },
    write(value) { this.written = value; },
    async close() { await this.interrupt(); if (this.cwd) await rm(this.cwd, { recursive: true, force: true }); },
  };
}

test('queue survives clients, idempotent submit, queued edit and removal', async () => {
  const chat = fakeChat(); const conversation = new TemporaryConversation(chat);
  try {
    conversation.submit({ id: 'a', message: '一', model: 'one', effort: 'high', fast: true, agentMode: true });
    conversation.submit({ id: 'a', message: '重复' });
    conversation.submit({ id: 'b', message: '二' });
    conversation.submit({ id: 'c', message: '三' });
    await conversation.edit('b', { message: '修改二' }); conversation.remove('c');
    assert.equal(chat.calls.length, 1);
    assert.equal(chat.calls[0].options.effort, 'high');
    assert.equal(conversation.snapshot().turns[0].steps[0].output, 'hi');
    chat.replies[0].resolve(); await tick();
    assert.equal(chat.calls[1].text, '修改二');
    chat.replies[1].resolve(); await tick();
    assert.deepEqual(conversation.turns.map(t => t.status), ['completed', 'completed']);
    assert.equal(conversation.snapshot().turns[0].steps[0].exitCode, 0);
  } finally { await conversation.close(); }
});

test('editing a past question resets context to prefix only; retry keeps selected options', async () => {
  const chat = fakeChat(); const c = new TemporaryConversation(chat);
  try {
    c.submit({ id: 'a', message: '保留' }); chat.replies[0].resolve(); await tick();
    c.submit({ id: 'b', message: '旧问题', model: 'selected' }); chat.replies[1].resolve(); await tick();
    c.submit({ id: 'c', message: '不应带入' }); chat.replies[2].resolve(); await tick();
    await c.edit('b', { message: '新问题' });
    assert.equal(c.turns.length, 2);
    assert.deepEqual(chat.contexts[0].map(m => m.content), ['保留', '回答']);
    assert.equal(chat.calls[3].model, 'selected');
    await c.stop(); await tick(); assert.equal(c.turns[1].status, 'stopped');
  } finally { await c.close(); }
});

test('plans require confirmation, input choices return actual wire result', async () => {
  const chat = fakeChat(); const c = new TemporaryConversation(chat);
  try {
    c.submit({ id: 'a', message: '先计划', planning: true, agentMode: true });
    assert.equal(chat.calls[0].options.agentMode, false);
    chat.replies[0].resolve(); await tick();
    assert.equal(c.turns[0].decision.type, 'plan');
    assert.equal(chat.calls.length, 1);
    c.decide({ requestId: 'plan-a', accept: true });
    assert.equal(chat.calls[1].text, '按刚才的计划执行。');
    chat.calls[1].options.onRequest({ id: 83, method: 'item/tool/requestUserInput', params: { questions: [{ id: 'q', question: '选择', options: [{ label: 'A' }] }] } });
    c.decide({ requestId: '83', answers: [{ questionId: 'q', selectedOptionIds: ['A'] }] });
    assert.deepEqual(chat.written, { id: 83, result: { answers: { q: { answers: ['A'] } } } });
    chat.replies[1].resolve(); await tick();
  } finally { await c.close(); }
});

test('images remain in memory and are excluded from polling snapshots', async () => {
  const c = new TemporaryConversation(fakeChat());
  try {
    c.submit({ message: '看图', images: ['data:image/png;base64,YQ=='] });
    assert.equal(c.turns[0].options.images.length, 1);
    assert.equal(c.snapshot().turns[0].imageCount, 1);
    assert.equal(JSON.stringify(c.snapshot()).includes('base64'), false);
    assert.throws(() => c.submit({ message: '无效', images: ['file:///private'] }), { status: 400 });
  } finally { await c.close(); }
});

test('temporary file downloads reject traversal and links outside workspace; close removes them', async () => {
  const chat = fakeChat(); chat.cwd = await mkdtemp(path.join(os.tmpdir(), 'wx-artifact-test-'));
  const root = chat.cwd;
  const c = new TemporaryConversation(chat);
  try {
    await mkdir(path.join(root, 'outputs')); await writeFile(path.join(root, 'outputs', 'hello.txt'), 'artifact');
    await c.scanFiles(); assert.deepEqual(c.files.map(f => f.path), ['outputs/hello.txt']);
    assert.equal(await readFile(await c.resolveFile('outputs/hello.txt'), 'utf8'), 'artifact');
    await assert.rejects(c.resolveFile('../private.txt'), { status: 403 });
    await symlink(os.tmpdir(), path.join(root, 'outside'), process.platform === 'win32' ? 'junction' : 'dir');
    await assert.rejects(c.resolveFile('outside/something'), err => err.status === 403 || err.code === 'ENOENT');
  } finally { await c.close(); }
  await assert.rejects(stat(root), { code: 'ENOENT' });
});

test('generated files get stable online links and stay in the static library after close', async () => {
  const workspace = await mkdtemp(path.join(os.tmpdir(), 'wx-publish-test-'));
  const previous = process.env.WENXIANG_STATIC_DIR;
  const staticRoot = path.join(workspace, 'static');
  process.env.WENXIANG_STATIC_DIR = staticRoot;
  const chat = fakeChat();
  chat.cwd = path.join(workspace, 'session');
  const config = { workspaceRoot: workspace, publicUrl: 'https://example.test', staticToken: 'static-token' };
  const conversation = new TemporaryConversation(chat, { getStaticConfig: () => config });
  const relative = 'outputs/画稿 (100%).svg';
  try {
    await mkdir(path.join(chat.cwd, 'outputs'), { recursive: true });
    await writeFile(path.join(chat.cwd, relative), 'first');
    await writeFile(path.join(chat.cwd, '说明.txt'), 'notes');
    await writeFile(path.join(chat.cwd, '.env'), 'private');
    const answer = await conversation.fileLinksReply();
    const svg = conversation.files.find(file => file.path === relative);
    assert.match(svg.downloadUrl, /%28.*%25%29\.svg\?token=static-token$/);
    assert.ok(answer.includes(`[${relative}](${svg.downloadUrl})`));
    assert.equal(conversation.files.length, 2);
    assert.equal(await conversation.fileLinksReply(), '');

    await writeFile(path.join(chat.cwd, relative), 'revised');
    await conversation.fileLinksReply();
    const revised = conversation.files.find(file => file.path === relative);
    assert.notEqual(svg.downloadUrl, revised.downloadUrl);
    await conversation.close();
    await assert.rejects(stat(chat.cwd), { code: 'ENOENT' });
    const readLink = ({ downloadUrl }) => readFile(resolveStaticFile(
      staticRoot, new URL(downloadUrl).pathname.slice('/files/'.length),
    ).abs, 'utf8');
    assert.equal(await readLink(svg), 'first');
    assert.equal(await readLink(revised), 'revised');
    const listed = await listStaticFiles(workspace, { publicUrl: config.publicUrl, token: config.staticToken });
    assert.equal(listed.files.length, 3);
    assert.ok(listed.files.some(file => file.downloadUrl === revised.downloadUrl));
  } finally {
    await conversation.close();
    if (previous === undefined) delete process.env.WENXIANG_STATIC_DIR;
    else process.env.WENXIANG_STATIC_DIR = previous;
    await rm(workspace, { recursive: true, force: true });
  }
});

test('HTTP polling resumes accepted work; file links expire when session closes', async () => {
  const chat = fakeChat(); chat.cwd = await mkdtemp(path.join(os.tmpdir(), 'wx-route-test-'));
  await writeFile(path.join(chat.cwd, 'result.txt'), 'result');
  const registry = createTemporaryChats({ createChat: () => new TemporaryConversation(chat) });
  const id = await registry.create(); const c = registry.get(id); await c.scanFiles();
  const app = express(); app.use(express.json()); attachTemporaryDownloads(app, registry); attachTemporaryRoutes(app, registry, {});
  const server = await new Promise(resolve => { const srv = app.listen(0, '127.0.0.1', () => resolve(srv)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const accepted = await fetch(`${base}/v1/temporary-chats/${id}/messages`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: 'a', message: '后台继续' }) }).then(r => r.json());
    assert.equal(accepted.busy, true);
    chat.replies[0].resolve(); await tick();
    const recovered = await fetch(`${base}/v1/temporary-chats/${id}`).then(r => r.json());
    assert.equal(recovered.turns[0].answer, '回答');
    const url = `${base}/temporary-files/${id}/result.txt?token=${c.downloadKey}`;
    assert.equal(await fetch(url).then(r => r.text()), 'result');
    assert.equal(await fetch(url.replace(c.downloadKey, 'wrong')).then(r => r.status), 401);
    await registry.close(id);
    assert.equal(await fetch(url).then(r => r.status), 404);
  } finally { await registry.close(id); await new Promise(resolve => server.close(resolve)); }
});

test('temporary calls use existing context without project checkout/session creation', async () => {
  const events = []; const questions = [];
  const session = createVoiceSession({ temporary: true, config: { ready: true }, send: e => events.push(e),
    checkout: () => { throw new Error('must not checkout'); },
    sessions: { createEphemeral: () => { throw new Error('must not create project session'); } },
    ask: async function* ({ question }) { questions.push(question); yield { type: 'delta', text: '临时回答。' }; yield { type: 'done' }; },
    tts: async () => Buffer.from('audio') });
  try {
    await session.start({}); session.onTranscript('临时问题', { final: true });
    for (let i = 0; i < 50 && !events.some(e => e.role === 'assistant' && e.final); i++) await new Promise(r => setTimeout(r, 5));
    assert.deepEqual(questions, ['临时问题']);
    assert.equal(events.some(e => e.role === 'assistant' && e.text === '临时回答。'), true);
  } finally { session.hangup(); }
});
