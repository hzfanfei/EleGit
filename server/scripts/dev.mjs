/** Dev: ngrok + keep-alive, companion restarts on server/src changes (Node --watch). */
process.env.WENXIANG_DEV_WATCH = "1";
await import("./keep-alive.mjs");
