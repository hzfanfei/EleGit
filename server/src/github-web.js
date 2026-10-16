import { resolve4 } from "node:dns/promises";
import https from "node:https";

// Single addresses published in https://api.github.com/meta under "web".
// The DNS address for github.com (often 20.205.243.166) times out from this network.
const WEB_FALLBACKS = [
  "4.237.22.38",
  "20.201.28.151",
  "20.205.243.161",
  "20.87.245.2",
  "20.87.245.0",
];

let preferredIp = WEB_FALLBACKS[0];

function unique(list) {
  return [...new Set(list.filter(Boolean))];
}

export function orderGithubWebIps(extra = []) {
  return unique([preferredIp, ...WEB_FALLBACKS, ...extra]);
}

function postOnce(ip, path, body, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      fn(value);
    };
    const req = https.request(
      {
        host: ip,
        servername: "github.com",
        method: "POST",
        path,
        headers: {
          Host: "github.com",
          Accept: "application/json",
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(body),
          "User-Agent": "wenxiang-local-server",
        },
        timeout: timeoutMs,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          finish(resolve, {
            status: res.statusCode || 0,
            text: Buffer.concat(chunks).toString("utf8"),
          });
        });
        res.on("error", (err) => finish(reject, err));
      },
    );
    req.on("timeout", () => {
      req.destroy();
      const err = new Error("连接 GitHub 超时，请再试一次");
      err.status = 502;
      err.code = "ETIMEDOUT";
      finish(reject, err);
    });
    req.on("error", (err) => finish(reject, err));
    req.write(body);
    req.end();
  });
}

function parseJson(text) {
  const trimmed = String(text || "").trim();
  if (!trimmed.startsWith("{")) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

async function dnsIps() {
  try {
    return await resolve4("github.com");
  } catch {
    return [];
  }
}

async function metaIps() {
  try {
    const res = await fetch("https://api.github.com/meta", {
      headers: {
        Accept: "application/vnd.github+json",
        "User-Agent": "wenxiang-local-server",
      },
      signal: AbortSignal.timeout(4000),
    });
    if (!res.ok) return [];
    const body = await res.json();
    return (body.web || [])
      .filter((item) => /^\d+\.\d+\.\d+\.\d+\/32$/.test(item))
      .map((item) => item.slice(0, item.indexOf("/")));
  } catch {
    return [];
  }
}

async function tryIps(ips, path, body, postImpl, timeoutMs, remember) {
  let last = new Error("连不上 GitHub，请再试一次");
  last.status = 502;
  for (const ip of ips) {
    try {
      const result = await postImpl(ip, path, body, timeoutMs);
      const json = parseJson(result.text);
      if (!json) {
        last = new Error("连不上 GitHub，请再试一次");
        last.status = 502;
        continue;
      }
      if (remember) preferredIp = ip;
      return {
        status: result.status,
        ok: result.status >= 200 && result.status < 300,
        text: result.text,
        json,
      };
    } catch (err) {
      last = err?.status ? err : Object.assign(new Error("连不上 GitHub，请再试一次"), { status: 502, cause: err });
    }
  }
  return { error: last };
}

export async function postGithubWeb(path, payload, { postImpl = postOnce, ips, timeoutMs = 4000 } = {}) {
  const body = JSON.stringify(payload ?? {});
  if (ips) {
    const found = await tryIps(unique(ips), path, body, postImpl, timeoutMs, false);
    if (found.error) throw found.error;
    return found;
  }
  const found = await tryIps(orderGithubWebIps(await dnsIps()), path, body, postImpl, timeoutMs, true);
  if (!found.error) return found;
  const more = await tryIps(await metaIps(), path, body, postImpl, timeoutMs, true);
  if (!more.error) return more;
  throw found.error;
}

export function toFetchResponse(result) {
  return {
    ok: result.ok,
    status: result.status,
    async text() {
      return result.text;
    },
  };
}
