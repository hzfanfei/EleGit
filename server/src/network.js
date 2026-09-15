import os from "node:os";

export function lanUrls(port) {
  const urls = [];
  const ifaces = os.networkInterfaces();
  for (const list of Object.values(ifaces)) {
    for (const info of list || []) {
      if (info.internal || info.family !== "IPv4") continue;
      urls.push(`http://${info.address}:${port}`);
    }
  }
  return urls;
}
