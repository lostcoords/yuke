// yuke:sse — the `text/event-stream` parser. It takes text chunks and answers each complete event once.

/** @typedef {{ event: string, data: string, id: string }} SseEvent */

// A line or an event above this is peer input the parser refuses, so a stuck stream cannot grow memory.
const MAX_EVENT_CHARS = 4 * 1024 * 1024;

// Follow the HTML event-stream rules: CR, LF, or CRLF end a line, and a blank line ends an event.
/** @param {(event: SseEvent) => void} onEvent @param {{ maxChars?: number, onRetry?: ((ms: number) => void) | undefined }} [options] @returns {(chunk: string) => void} */
export function sseParser(onEvent, { maxChars = MAX_EVENT_CHARS, onRetry } = {}) {
  let rest = "";
  let first = true;
  /** @type {string[]} */
  let data = [];
  let size = 0;
  let event = "";
  // The last id persists across events, as the standard asks.
  let id = "";
  /** @param {string} line */
  const take = (line) => {
    if (line === "") {
      if (data.length !== 0) onEvent({ event: event || "message", data: data.join("\n"), id });
      data = [];
      size = 0;
      event = "";
      return;
    }
    if (line[0] === ":") return;
    const colon = line.indexOf(":");
    const field = colon < 0 ? line : line.slice(0, colon);
    let value = colon < 0 ? "" : line.slice(colon + 1);
    if (value[0] === " ") value = value.slice(1);
    if (field === "data") {
      size += value.length + 1;
      if (size > maxChars) throw new Error("the event exceeds the size limit");
      data.push(value);
    } else if (field === "event") event = value;
    else if (field === "id" && !value.includes("\0")) id = value;
    else if (field === "retry" && /^[0-9]+$/.test(value)) onRetry?.(Number(value));
  };
  return (chunk) => {
    rest += chunk;
    if (first && rest.length !== 0) {
      if (rest[0] === "\ufeff") rest = rest.slice(1);
      first = rest.length === 0;
    }
    let start = 0;
    while (true) {
      const lf = rest.indexOf("\n", start);
      const cr = rest.indexOf("\r", start);
      const end = cr < 0 ? lf : lf < 0 ? cr : Math.min(cr, lf);
      if (end < 0) break;
      // A CR at the end of the chunk may start a CRLF, so it waits for the next chunk.
      if (end === cr && end === rest.length - 1) break;
      take(rest.slice(start, end));
      start = end + (end === cr && rest[end + 1] === "\n" ? 2 : 1);
    }
    rest = rest.slice(start);
    if (rest.length > maxChars) throw new Error("the event line exceeds the size limit");
  };
}
