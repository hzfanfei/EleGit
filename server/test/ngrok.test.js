import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  ensureNgrok,
  ngrokAlreadyOpen,
  ngrokHttpArgs,
  publicHostFromUrl,
  shouldAutostartNgrok,
} from "../src/ngrok.js";

describe("ngrok autostart", () => {
  it("builds a reserved-domain http command from the public url", () => {
    assert.equal(publicHostFromUrl("https://demo.ngrok-free.dev/"), "demo.ngrok-free.dev");
    assert.deepEqual(
      ngrokHttpArgs({ port: 8787, publicUrl: "https://demo.ngrok-free.dev" }),
      ["http", "8787", "--log=stdout", "--url", "demo.ngrok-free.dev"],
    );
  });

  it("autostarts only for ngrok public urls unless forced", () => {
    assert.equal(shouldAutostartNgrok({ WENXIANG_PUBLIC_URL: "https://demo.ngrok-free.dev" }), true);
    assert.equal(shouldAutostartNgrok({ WENXIANG_PUBLIC_URL: "https://example.com" }), false);
    assert.equal(
      shouldAutostartNgrok({ WENXIANG_PUBLIC_URL: "https://example.com", WENXIANG_NGROK: "1" }),
      true,
    );
    assert.equal(
      shouldAutostartNgrok({ WENXIANG_PUBLIC_URL: "https://demo.ngrok-free.dev", WENXIANG_NGROK: "0" }),
      false,
    );
  });

  it("treats an existing local inspector tunnel as already open", async () => {
    const open = await ngrokAlreadyOpen({
      fetchImpl: async () => ({
        ok: true,
        json: async () => ({
          tunnels: [{ public_url: "https://demo.ngrok-free.dev" }],
        }),
      }),
    });
    assert.equal(open, true);

    const closed = await ngrokAlreadyOpen({
      fetchImpl: async () => {
        throw new Error("ECONNREFUSED");
      },
    });
    assert.equal(closed, false);
  });

  it("does not spawn ngrok when the inspector already has a tunnel", async () => {
    let spawned = false;
    const result = await ensureNgrok({
      env: { WENXIANG_PUBLIC_URL: "https://demo.ngrok-free.dev" },
      fetchImpl: async () => ({
        ok: true,
        json: async () => ({ tunnels: [{ public_url: "https://demo.ngrok-free.dev" }] }),
      }),
      spawnImpl: () => {
        spawned = true;
        return { exitCode: null };
      },
    });
    assert.equal(result.reason, "already");
    assert.equal(spawned, false);
  });
});
