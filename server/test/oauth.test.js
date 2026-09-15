import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  callbackUrl,
  createOAuthSessions,
  normalizePublicBase,
  suggestedCallbackUrls,
} from "../src/oauth.js";

describe("oauth urls", () => {
  it("normalizes the public base and builds the callback", () => {
    assert.equal(normalizePublicBase("http://192.168.1.8:8787/"), "http://192.168.1.8:8787");
    assert.equal(
      callbackUrl("https://abc.trycloudflare.com"),
      "https://abc.trycloudflare.com/oauth/github/callback",
    );
  });

  it("rejects a non-http base", () => {
    assert.throws(() => normalizePublicBase("ftp://x"), /http/);
  });

  it("lists LAN and localhost callbacks", () => {
    const urls = suggestedCallbackUrls({
      lanUrls: ["http://10.0.0.2:8787"],
      tunnelUrl: "https://foo.trycloudflare.com",
    });
    assert.ok(urls.includes("http://127.0.0.1:8787/oauth/github/callback"));
    assert.ok(urls.includes("http://10.0.0.2:8787/oauth/github/callback"));
    assert.ok(urls.includes("https://foo.trycloudflare.com/oauth/github/callback"));
  });
});

describe("oauth sessions", () => {
  it("returns an authorize URL with state and redirect", () => {
    const oauth = createOAuthSessions();
    const started = oauth.start({
      clientId: "client-1",
      publicBaseUrl: "http://192.168.1.8:8787",
    });
    assert.match(started.authorizeUrl, /github\.com\/login\/oauth\/authorize/);
    assert.match(started.authorizeUrl, /client_id=client-1/);
    assert.match(started.authorizeUrl, /redirect_uri=http/);
    assert.equal(oauth.peek(started.state).status, "pending");
    oauth.complete(started.state);
    assert.equal(oauth.peek(started.state).status, "connected");
  });
});
