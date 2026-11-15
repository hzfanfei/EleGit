export const TASK_COMPLETED_MARKER = "===TASK_COMPLETED===";

/** Find a control marker at a line start, outside fenced code examples. */
export function findTaskCompletionMarker(source) {
  let fence = null;
  let offset = 0;
  for (const line of String(source).split("\n")) {
    const trimmed = line.trimStart();
    if (fence) {
      const closing = trimmed.trimEnd();
      if (closing.length >= fence.length && [...closing].every((char) => char === fence[0])) {
        fence = null;
      }
    } else {
      const opening = trimmed.match(/^(`{3,}|~{3,})/);
      if (opening) {
        fence = opening[1];
      } else if (trimmed.startsWith(TASK_COMPLETED_MARKER)) {
        const index = offset + line.length - trimmed.length;
        return { index, end: index + TASK_COMPLETED_MARKER.length };
      }
    }
    offset += line.length + 1;
  }
  return null;
}
