import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { describe, it } from "node:test";
import { promisify } from "node:util";
import {
  ensureNgrok,
  findTunnelForPublicUrl,
  killWenxiangNgrok,
  ngrokAlreadyOpen,
  ngrokHttpArgs,
  ngrokStopScript,
  ngrokTunnelReady,
  probePublicHealth,
  publicHostFromUrl,
  recoverNgrok,
  shouldAutostartNgrok,
} from "../src/ngrok.js";

const execFileAsync = promisify(execFile);

function tunnelBody(host) {
  return {
    ok: true,
    json: async () => ({
      tunnels: host
        ? [{ public_url: host, config: { addr: "http://localhost:8787" } }]
        : [],
    }),
  };
}

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
      publicUrl: "https://demo.ngrok-free.dev",
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

  it("matches reserved-domain tunnels and public health probes", async () => {
    const tunnels = [
      { name: "command_line", public_url: "https://demo.ngrok-free.dev", config: { addr: "http://localhost:8787" } },
    ];
    assert.equal(findTunnelForPublicUrl(tunnels, "https://demo.ngrok-free.dev/foo").name, "command_line");
    assert.equal(ngrokTunnelReady(tunnels, { publicUrl: "https://demo.ngrok-free.dev", port: 8787 }), true);
    assert.equal(ngrokTunnelReady(tunnels, { publicUrl: "https://other.ngrok.app", port: 8787 }), false);

    const health = await probePublicHealth("https://demo.ngrok-free.dev", {
      fetchImpl: async () => ({
        ok: true,
        json: async () => ({ ok: true, service: "wenxiang" }),
      }),
    });
    assert.equal(health.ok, true);
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

  it("confirms a spawned tunnel against the requested public url", async () => {
    const previous = process.env.WENXIANG_PUBLIC_URL;
    process.env.WENXIANG_PUBLIC_URL = "https://other.ngrok.app";
    let fetches = 0;
    try {
      const result = await ensureNgrok({
        env: { WENXIANG_PUBLIC_URL: "https://demo.ngrok-free.dev", WENXIANG_NGROK: "1" },
        publicUrl: "https://demo.ngrok-free.dev",
        port: 8787,
        readyTimeoutMs: 700,
        fetchImpl: async () => {
          fetches += 1;
          const host = fetches === 1 ? "https://missing.ngrok.app" : "https://demo.ngrok-free.dev";
          return tunnelBody(host);
        },
        spawnImpl: () => ({ exitCode: null }),
        whichImpl: () => "ngrok",
      });
      assert.equal(result.reason, "spawned");
    } finally {
      if (previous === undefined) delete process.env.WENXIANG_PUBLIC_URL;
      else process.env.WENXIANG_PUBLIC_URL = previous;
    }
  });

  it("splits the windows stop script so if is its own statement", () => {
    const script = ngrokStopScript("wenxiang.ngrok.app");
    assert.match(script, /;\s*if \(\$procs\)/);
    assert.match(script, /wenxiang\\\.ngrok\\\.app/);
    assert.doesNotMatch(script, /\}\s+if \(\$procs\)/);
  });

  it("runs the windows stop script against a fake ngrok process", { skip: process.platform !== "win32" }, async () => {
    const script = ngrokStopScript("wenxiang.ngrok.app");
    const dry = script
      .replace(
        "Get-CimInstance Win32_Process -Filter \"Name='ngrok.exe'\" -ErrorAction SilentlyContinue",
        "@([pscustomobject]@{ ProcessId = 4242; CommandLine = 'ngrok.exe http 8787 --url https://wenxiang.ngrok.app' }, [pscustomobject]@{ ProcessId = 8888; CommandLine = 'ngrok.exe http 8888 --url https://wenxiangweb.ngrok.app' })",
      )
      .replace(
        "Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue",
        "Write-Output $_.ProcessId",
      );
    const { stdout } = await execFileAsync(
      "powershell.exe",
      ["-NoProfile", "-NonInteractive", "-Command", dry],
      { windowsHide: true },
    );
    assert.match(stdout, /4242/);
    assert.doesNotMatch(stdout, /8888/);
  });

  it("kills and restarts when the inspector still lists a stale tunnel", async () => {
    let killed = false;
    let spawned = false;
    let fetchesAfterKill = 0;
    const result = await recoverNgrok({
      env: { WENXIANG_PUBLIC_URL: "https://demo.ngrok-free.dev", WENXIANG_NGROK: "1" },
      publicUrl: "https://demo.ngrok-free.dev",
      port: 8787,
      settleMs: 0,
      clearTimeoutMs: 1000,
      readyTimeoutMs: 1000,
      platform: "win32",
      execFileImpl: async () => {
        killed = true;
      },
      fetchImpl: async () => {
        if (!killed) return tunnelBody("https://demo.ngrok-free.dev");
        fetchesAfterKill += 1;
        if (fetchesAfterKill === 1) return tunnelBody("https://demo.ngrok-free.dev");
        if (!spawned) return tunnelBody("");
        return tunnelBody("https://demo.ngrok-free.dev");
      },
      spawnImpl: () => {
        spawned = true;
        return { exitCode: null };
      },
      whichImpl: () => "ngrok",
    });
    assert.equal(killed, true);
    assert.equal(spawned, true);
    assert.equal(result.reason, "spawned");
  });

  it("reports failure when the stale tunnel is still held after the kill", async () => {
    await assert.rejects(
      () =>
        recoverNgrok({
          env: { WENXIANG_PUBLIC_URL: "https://demo.ngrok-free.dev", WENXIANG_NGROK: "1" },
          publicUrl: "https://demo.ngrok-free.dev",
          port: 8787,
          settleMs: 0,
          clearTimeoutMs: 0,
          platform: "win32",
          execFileImpl: async () => {},
          fetchImpl: async () => tunnelBody("https://demo.ngrok-free.dev"),
          spawnImpl: () => {
            throw new Error("should not spawn");
          },
          whichImpl: () => "ngrok",
        }),
      (err) => err.code === "NGROK_STILL_HELD",
    );
  });

  it("still stops an external ngrok when a child handle exists", async () => {
    let command = "";
    const child = { killed: false, kill() { this.killed = true; } };
    const result = await killWenxiangNgrok({
      child,
      env: { WENXIANG_PUBLIC_URL: "https://wenxiang.ngrok.app" },
      platform: "win32",
      settleMs: 0,
      execFileImpl: async (_bin, args) => {
        command = args.at(-1);
      },
    });
    assert.equal(child.killed, true);
    assert.equal(result.method, "child+host");
    assert.match(command, /;\s*if \(\$procs\)/);
  });
});
