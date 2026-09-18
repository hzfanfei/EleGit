import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { whichSync } from "./which.js";

const execFileAsync = promisify(execFile);

export function findPandoc() {
  return whichSync("pandoc");
}

/**
 * Convert HTML (file or string) to GitHub-flavored Markdown via pandoc.
 * Returns false when pandoc is missing or conversion fails.
 */
export async function htmlToMarkdown({
  htmlPath,
  html,
  outPath,
  pandocPath = findPandoc(),
  extractMediaDir = "",
  resourcePath = "",
}) {
  const pandoc = String(pandocPath || findPandoc() || "").trim();
  if (!pandoc) return false;
  const args = ["-f", "html", "-t", "gfm", "--wrap=none"];
  const mediaDir = String(extractMediaDir || "").trim();
  if (mediaDir) args.push(`--extract-media=${mediaDir}`);
  const resources = String(resourcePath || "").trim();
  if (resources) args.push(`--resource-path=${resources}`);
  args.push("-o", outPath);
  try {
    if (htmlPath) {
      args.push(htmlPath);
      await execFileAsync(pandoc, args, { windowsHide: true, maxBuffer: 32 * 1024 * 1024 });
    } else {
      await execFileAsync(pandoc, args, {
        input: String(html || ""),
        windowsHide: true,
        maxBuffer: 32 * 1024 * 1024,
      });
    }
    return true;
  } catch {
    return false;
  }
}
