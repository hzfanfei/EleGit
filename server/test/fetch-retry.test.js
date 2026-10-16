import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { fetchWithRetry, isTransientFetchError } from "../src/fetch-retry.js";

function connectTimeout() {
  const err = new TypeError("fetch failed");
  err.cause = Object.assign(new Error("Connect Timeout Error"), { code: "UND_ERR_CONNECT_TIMEOUT" });
  return err;
}

describe("fetch retry", () => {
  it("treats a GitHub connect timeout as transient", () => {
    assert.equal(isTransientFetchError(connectTimeout()), true);
    const abort = new Error("aborted");
    abort.name = "AbortError";
    assert.equal(isTransientFetchError(abort), false);
    const timed = new Error("The operation was aborted due to timeout");
    timed.name = "TimeoutError";
    assert.equal(isTransientFetchError(timed), true);
  });

  it("retries a connect timeout and then returns the response", async () => {
    let calls = 0;
    const res = await fetchWithRetry(
      "https://github.com/login/oauth/access_token",
      { method: "POST" },
      {
        delayMs: 0,
        fetchImpl: async () => {
          calls += 1;
          if (calls === 1) throw connectTimeout();
          return new Response(JSON.stringify({ access_token: "tok" }), { status: 200 });
        },
      },
    );
    assert.equal(calls, 2);
    assert.equal((await res.json()).access_token, "tok");
  });

  it("says the connection timed out after the retries are used up", async () => {
    await assert.rejects(
      () =>
        fetchWithRetry("https://github.com/login/oauth/access_token", {}, {
          attempts: 2,
          delayMs: 0,
          fetchImpl: async () => {
            throw connectTimeout();
          },
        }),
      /连接 GitHub 超时/,
    );
  });
});
