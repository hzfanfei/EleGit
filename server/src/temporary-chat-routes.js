import { TemporaryChat } from "./temporary-chat.js";
import { runVoiceTurn } from "./voice-call.js";
import { createVoiceProviders } from "./voice-ws.js";
import { resolveVoiceConfig, withTtsVoice } from "./voice-config.js";
import { openSse, writeSse } from "./sse.js";
import { writeAudioToSse } from "./spoken-tts.js";
import { requestSignal } from "./http-signal.js";

export function attachTemporaryDownloads(app, registry) {
  app.get("/temporary-files/:id/*", async (req, res) => {
    try {
      const conversation = registry.get(req.params.id);
      if (req.query.token !== conversation.downloadKey) return res.status(401).json({ error: "下载链接无效" });
      const file = await conversation.resolveFile(req.params[0]);
      res.setHeader("Cache-Control", "no-store");
      res.download(file);
    } catch (err) { res.status(err.status || (err.code === "ENOENT" ? 404 : 500)).json({ error: "临时文件不可用或已清理" }); }
  });
}

export function attachTemporaryRoutes(app, registry, { executable, defaultModel, ttsVoice, resolveConfig = resolveVoiceConfig, createProviders = createVoiceProviders }) {
  const route = (method, suffix, handler) => app[method](`/v1/temporary-chats/:id${suffix}`, async (req, res) => {
    try {
      const conversation = registry.get(req.params.id);
      await handler(req, res, conversation);
    } catch (err) {
      if (!res.headersSent) res.status(err.status || 500).json({ error: err.message || "临时会话失败" });
      else { writeSse(res, { type: "error", error: err.message || "语音失败" }); res.end(); }
    }
  });
  const snapshot = (res, conversation) => {
    res.setHeader("Cache-Control", "no-store");
    res.json({ ...conversation.snapshot(), downloadKey: conversation.downloadKey });
  };
  route("get", "", (req, res, conversation) => {
    if (Number(req.query.version) === conversation.version) { res.setHeader("Cache-Control", "no-store"); res.json({ unchanged: true }); }
    else snapshot(res, conversation);
  });
  route("post", "/messages", (req, res, conversation) => { conversation.submit(req.body || {}); snapshot(res, conversation); });
  route("patch", "/messages/:turnId", async (req, res, conversation) => { await conversation.edit(req.params.turnId, req.body || {}); snapshot(res, conversation); });
  route("delete", "/messages/:turnId", (req, res, conversation) => { conversation.remove(req.params.turnId); snapshot(res, conversation); });
  route("post", "/decision", (req, res, conversation) => { conversation.decide(req.body || {}); snapshot(res, conversation); });
  route("put", "/options", (req, res, conversation) => {
    const body = req.body || {};
    conversation.voiceOptions = { model: typeof body.model === "string" ? body.model.slice(0, 200) : undefined, effort: typeof body.effort === "string" ? body.effort.slice(0, 32) : undefined, agentMode: body.agentMode === true, fast: body.fast === true };
    res.json({ ok: true });
  });
  route("post", "/speed", async (req, res) => {
    const chat = new TemporaryChat({ executable, model: req.body?.model || defaultModel });
    const start = Date.now(); let first; let answer = "";
    const timeout = setTimeout(() => { void chat.close(); }, 45_000);
    try {
      await chat.prompt("请从一数到二十，用空格分隔，不要其他文字。", (delta) => { first ??= Date.now(); answer += delta; }, req.body?.model, [], undefined, { effort: req.body?.effort, fast: req.body?.fast });
      res.json({ firstTokenMs: (first || Date.now()) - start, totalMs: Date.now() - start, characters: answer.length });
    } finally { clearTimeout(timeout); await chat.close(); }
  });
  route("post", "/voice-turn", async (req, res, conversation) => {
    const config = withTtsVoice(resolveConfig(), ttsVoice?.());
    const providers = createProviders(config);
    if (!config.ready || !providers.tts) return res.status(503).json({ error: "语音未配置" });
    const question = String(req.body?.message || "").trim();
    if (!question || question.length > 100_000) return res.status(400).json({ error: "请输入问题" });
    const signal = requestSignal(req, res);
    openSse(res);
    await runVoiceTurn({
      question, signal, tts: providers.tts,
      ttsStream: providers.tts.stream,
      ask: (q, s) => conversation.voice(q, s),
      onDelta: ({ text, engine }) => writeSse(res, { type: "delta", text, engine }),
      onCaption: (text) => writeSse(res, { type: "caption", text }),
      onAudio: (buf) => {
        writeSse(res, { type: "state", phase: "speak" });
        writeAudioToSse(res, (r, event) => writeSse(r, { type: "audio", ...event }), buf, config, signal);
      },
      onDone: ({ text, engine }) => writeSse(res, { type: "done", answer: text, engine }),
    });
    res.end();
  });
}
