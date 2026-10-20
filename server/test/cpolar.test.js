import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  cpolarHttpArgs,
  cpolarTargetFromPublicUrl,
  cpolarTunnelReady,
  shouldAutostartCpolar,
} from "../src/cpolar.js";

describe("cpolar public host", () => {
  it("maps reserved China hostnames to subdomain and region", () => {
    assert.deepEqual(cpolarTargetFromPublicUrl("https://wenxiang.cpolar.cn"), {
      subdomain: "wenxiang",
      region: "cn",
    });
    assert.deepEqual(cpolarTargetFromPublicUrl("https://wenxiang.vip.cpolar.cn/"), {
      subdomain: "wenxiang",
      region: "cn_vip",
    });
    assert.deepEqual(cpolarTargetFromPublicUrl("https://wenxiang.cpolar.top"), {
      subdomain: "wenxiang",
      region: "cn_top",
    });
  });

  it("autostarts only for cpolar hosts unless forced", () => {
    assert.equal(shouldAutostartCpolar({ WENXIANG_PUBLIC_URL: "https://wenxiang.cpolar.cn" }), true);
    assert.equal(shouldAutostartCpolar({ WENXIANG_PUBLIC_URL: "https://wenxiang.ngrok.app" }), false);
    assert.equal(
      shouldAutostartCpolar({
        WENXIANG_PUBLIC_URL: "https://wenxiang.cpolar.cn",
        WENXIANG_CPOLAR: "0",
      }),
      false,
    );
  });

  it("builds the reserved-domain http command", () => {
    assert.deepEqual(
      cpolarHttpArgs({
        port: 8787,
        publicUrl: "https://wenxiang.cpolar.cn",
        env: {},
      }),
      ["http", "8787", "-log=stdout", "-subdomain=wenxiang", "-region=cn"],
    );
  });

  it("treats the inspector URL list as ready when the public host matches", () => {
    assert.equal(
      cpolarTunnelReady(["http://wenxiang.cpolar.cn", "https://wenxiang.cpolar.cn"], {
        publicUrl: "https://wenxiang.cpolar.cn",
      }),
      true,
    );
    assert.equal(
      cpolarTunnelReady(["https://2fab24e4.r8.cpolar.cn"], {
        publicUrl: "https://wenxiang.cpolar.cn",
      }),
      false,
    );
  });
});
