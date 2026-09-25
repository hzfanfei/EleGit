import fs from "node:fs";

const s = fs.readFileSync(
  "C:/Users/Administrator/AppData/Local/cursor-agent/versions/2026.05.24-dda726e/879.index.js",
  "utf8",
);
const text = fs.readFileSync(
  "C:/Users/Administrator/AppData/Local/cursor-agent/versions/2026.05.24-dda726e/879.index.js",
  "utf8",
);
const needle = "isEnabled:!1";
let j = 0;
let c = 0;
while ((j = text.indexOf(needle, j)) !== -1 && c < 8) {
  console.log(text.slice(Math.max(0, j - 100), j + 80));
  console.log("---");
  j += needle.length;
  c += 1;
}
console.log("count", c);
