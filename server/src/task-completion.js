export const TASK_COMPLETED_MARKER = "===TASK_COMPLETED===";

/** Find a control marker outside fenced code and inline code examples. */
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
      } else {
        let inlineFence = null;
        for (const token of line.matchAll(/(`+)|===TASK_COMPLETED===/g)) {
          if (token[1]) {
            if (!inlineFence) inlineFence = token[1];
            else if (inlineFence === token[1]) inlineFence = null;
          } else if (!inlineFence) {
            const index = offset + token.index;
            return { index, end: index + TASK_COMPLETED_MARKER.length };
          }
        }
      }
    }
    offset += line.length + 1;
  }
  return null;
}
