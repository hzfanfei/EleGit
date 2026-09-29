/** Detached ACP host. Survives companion --watch reloads and publishes a finished answer. */
import { publishInboxNotice } from "../src/notifications.js";
import { startTurnRelay } from "../src/turn-relay.js";
import { TURN_RELAY_PORT, relaySourceStamp, writeRelayInfo } from "../src/turn-relay-client.js";

const relay = await startTurnRelay({
  port: TURN_RELAY_PORT,
  publish: (workspaceRoot, notice) => publishInboxNotice(workspaceRoot, notice),
});
writeRelayInfo(process.pid, relay.port, relaySourceStamp());
process.title = "wenxiang-turn-relay";
