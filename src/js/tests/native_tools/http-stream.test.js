import { fetch } from "yuke";
import { check, equal } from "yuke:test";

globalThis.httpChunks = 0;

/** @param {Promise<unknown>} promise @returns {Promise<string>} */
const failure = promise => promise.then(() => "unexpected success", error => error.message);

async function sse() {
  const response = await fetch(httpUrl, { timeoutMs: 2000 });
  equal(response.headers.get("content-type"), "text/event-stream");
  equal(await failure(response.body.read({ maxBytes: 3 })), "a read option is invalid");
  const chunks = [];
  for await (const chunk of response.body) {
    chunks.push(chunk);
    globalThis.httpChunks = chunks.length;
  }
  // The first event reached JavaScript before the peer wrote the rest, the split character arrived whole, and the stray byte came last, repaired.
  equal(chunks[0], "data: one\n\n");
  check("the stream arrived in more than one chunk", chunks.length >= 2);
  equal(chunks.join(""), "data: one\n\ndata: 世界\n\ndata: end\n\ufffd");
  equal(await response.body.read(), null);
}

async function cancel() {
  const response = await fetch(httpUrl, { timeoutMs: 2000 });
  const pending = response.body.read();
  equal(await failure(response.body.read()), "a body read is already pending");
  response.body.cancel();
  equal(await failure(pending), "the request was canceled");
  equal(await failure(response.body.read()), "the response body is closed");
  equal(await failure(response.text()), "the response body is closed");
  // A body nobody reads stays parked until the host closes.
  globalThis.httpUnread = await fetch(httpUrl, { timeoutMs: 2000 });
  globalThis.httpChunks = 1;
}

const run = httpMode === "sse" ? sse : cancel;
run().then(() => { globalThis.httpDone = true; }, error => { globalThis.httpError = httpMode + ": " + error.message + "\n" + error.stack; globalThis.httpDone = true; });
