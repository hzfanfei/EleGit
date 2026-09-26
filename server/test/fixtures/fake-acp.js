import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin });
const sessionId = "fake-acp-session";
const seen = [];
let askResume = null;
let planOutcome = "";

function write(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.result && !msg.method && askResume) {
    const resume = askResume;
    askResume = null;
    resume(msg.result);
    return;
  }
  const reply = (result) => write({ jsonrpc: "2.0", id: msg.id, result });

  if (msg.method === "initialize") {
    reply({
      protocolVersion: 1,
      authMethods: [{ id: "cursor_login" }],
      agentCapabilities: {
        sessionCapabilities: { modes: { availableModes: [{ id: "ask" }] } },
      },
    });
    return;
  }
  if (
    msg.method === "authenticate" ||
    msg.method === "session/set_mode" ||
    msg.method === "session/set_config_option" ||
    msg.method === "session/set_model"
  ) {
    reply({});
    return;
  }
  if (msg.method === "session/new") {
    reply({
      sessionId,
      modes: { currentModeId: "agent", availableModes: [{ id: "ask" }] },
    });
    return;
  }
  if (msg.method === "session/prompt") {
    const text = (msg.params?.prompt || []).map((p) => p.text || "").join("");
    if (process.env.FAKE_ACP_PLAN === "1") {
      write({
        jsonrpc: "2.0",
        id: 78,
        method: "cursor/create_plan",
        params: {
          name: "改登录",
          overview: "先改一处",
          plan: "1. 改文件",
          todos: [{ id: "t1", content: "改登录", status: "pending" }],
        },
      });
      askResume = (result) => {
        planOutcome = result?.outcome?.outcome || "";
        answerPrompt(msg);
      };
      return;
    }
    if (process.env.FAKE_ACP_ASK === "1" && text.includes("请选择")) {
      write({
        jsonrpc: "2.0",
        id: 77,
        method: "cursor/ask_question",
        params: {
          title: "选一个",
          questions: [
            {
              id: "q1",
              prompt: "用哪个？",
              allowMultiple: false,
              options: [
                { id: "a", label: "甲" },
                { id: "b", label: "乙" },
              ],
            },
          ],
        },
      });
      askResume = () => answerPrompt(msg);
      return;
    }
    const delayMs = Number(process.env.FAKE_ACP_PROMPT_DELAY_MS || 0);
    if (delayMs > 0) {
      setTimeout(() => answerPrompt(msg), delayMs);
      return;
    }
    answerPrompt(msg);
    return;
  }
});

function answerPrompt(msg) {
  const reply = (result) => write({ jsonrpc: "2.0", id: msg.id, result });
  const text = (msg.params?.prompt || []).map((p) => p.text || "").join("");
  seen.push(text);
  if (/write file|apply_patch/i.test(text)) {
    write({
      jsonrpc: "2.0",
      id: 9000 + seen.length,
      method: "session/request_permission",
      params: {
        sessionId,
        toolCall: { title: "Write file", kind: "edit" },
        options: [
          { optionId: "allow-once", name: "Allow" },
          { optionId: "reject-once", name: "Reject" },
        ],
      },
    });
  }
  const recall = /restore after reconnect/i.test(text) ? "seeded" : seen.length > 1 ? "followup" : "first";
  const persona = /You are 问象/.test(text) ? "persona:" : "";
  const planBit = planOutcome ? `plan:${planOutcome}:` : "";
  planOutcome = "";
  write({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: `hidden-thought:${seen.length}` },
      },
    },
  });
  write({
    jsonrpc: "2.0",
    method: "session/update",
    params: {
      sessionId,
      update: {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: `${persona}${planBit}${recall}:${seen.length}` },
      },
    },
  });
  reply({ stopReason: "end_turn" });
}
