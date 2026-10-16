import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { orderGithubWebIps, postGithubWeb } from "../src/github-web.js";

describe("github web", () => {
  it("tries the published web address before the flaky DNS address", () => {
    const ips = orderGithubWebIps(["20.205.243.166"]);
    assert.equal(ips[0], "4.237.22.38");
    assert.equal(ips.at(-1), "20.205.243.166");
  });

  it("skips a timed-out address and keeps a JSON token response", async () => {
    const seen = [];
    const result = await postGithubWeb(
      "/login/oauth/access_token",
      { client_id: "id", code: "code" },
      {
        ips: ["20.205.243.166", "4.237.22.38"],
        postImpl: async (ip) => {
          seen.push(ip);
          if (ip === "20.205.243.166") {
            const err = new Error("连接 GitHub 超时，请再试一次");
            err.status = 502;
            throw err;
          }
          return { status: 200, text: JSON.stringify({ access_token: "gho_tok" }) };
        },
      },
    );
    assert.deepEqual(seen, ["20.205.243.166", "4.237.22.38"]);
    assert.equal(result.json.access_token, "gho_tok");
  });

  it("skips an HTML error page and uses the next address", async () => {
    const result = await postGithubWeb(
      "/login/oauth/access_token",
      {},
      {
        ips: ["20.205.243.168", "4.237.22.38"],
        postImpl: async (ip) => {
          if (ip === "20.205.243.168") return { status: 400, text: "<html>Bad request</html>" };
          return { status: 200, text: JSON.stringify({ error: "bad_verification_code" }) };
        },
      },
    );
    assert.equal(result.json.error, "bad_verification_code");
  });
});
