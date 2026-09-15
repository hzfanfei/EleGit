import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";

export function whichSync(bin) {
  if (!bin) return "";
  if (bin.includes("/") || bin.includes("\\")) {
    return existsSync(bin) ? bin : "";
  }
  const dirs = [
    ...(process.env.PATH || "").split(path.delimiter),
    path.join(os.homedir(), ".local", "bin"),
    path.join(os.homedir(), "AppData", "Local", "cursor-agent"),
    path.join(process.env.LOCALAPPDATA || "", "cursor-agent"),
    path.join(process.env.LOCALAPPDATA || "", "Programs", "cursor"),
  ].filter(Boolean);

  const exts =
    process.platform === "win32"
      ? (process.env.PATHEXT || ".EXE;.CMD;.BAT;.COM").split(";").filter(Boolean)
      : [""];

  for (const dir of dirs) {
    const exact = path.join(dir, bin);
    if (existsSync(exact)) return exact;
    for (const ext of exts) {
      if (!ext) continue;
      const withExt = path.join(dir, `${bin}${ext}`);
      if (existsSync(withExt)) return withExt;
    }
  }
  return "";
}
