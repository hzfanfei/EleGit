import readline from "node:readline";

const rl = readline.createInterface({ input: process.stdin });
const sessionId = "fake-acp-session";
const seen = [];

function write(obj) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
}

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
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
  if (msg.method === "authenticate" || msg.method === "session/set_mode") {
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
    write({
      jsonrpc: "2.0",
      method: "session/update",
      params: {
        sessionId,
        update: {
          sessionUpdate: "agent_message_chunk",
          content: { type: "text", text: `${recall}:${seen.length}` },
        },
      },
    });
    reply({ stopReason: "end_turn" });
  }
});
