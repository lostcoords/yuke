import { fetch } from "yuke";
import { check, equal } from "yuke:test";

// The head refuses these before any body exists.
const failures = {
  redirect: "the request was redirected",
  malformed: "the host could not complete the request",
  bad_status: "the host could not complete the request",
  compressed: "the host could not complete the request",
  refused: "the host could not complete the request",
  partial_head: "the request timed out",
  upload_stall: "the request timed out",
  headers: "the response exceeds the size limit",
  header_bytes: "the response exceeds the size limit",
  stall: "the request timed out",
};
// The head arrives, and the body read fails.
const bodyFailures = {
  oversize: "the response exceeds the size limit",
  truncated: "the host could not complete the request",
  oversized_chunk: "the response exceeds the size limit",
  slow_body: "the request timed out",
  close_oversize: "the response exceeds the size limit",
};

async function runPool() {
  const read = async (url = httpUrl) => equal((await (await fetch(url)).json()).ok, true);
  if (httpPoolCase === "concurrent") {
    await Promise.all(Array.from({ length: 10 }, () => read()));
    return;
  }
  await read(httpUrl.replace(/^http:/, "HTTP:"));
  if (httpPoolCase === "recover" || httpPoolCase === "no_replay") {
    let failed = false;
    try { await (await fetch(httpUrl, httpPoolCase === "no_replay" ? { method: "POST", body: "" } : undefined)).text(); }
    catch (error) { failed = true; equal(error.message, httpPoolCase === "no_replay" ? "the host could not complete the request" : failures[httpMode] ?? bodyFailures[httpMode]); }
    check("failed request did not replay", failed);
  }
  if (httpPoolCase === "origins") await read(httpSecondUrl);
  await read();
  if (httpPoolCase === "origins") await read(httpSecondUrl);
}

async function run() {
  if (globalThis.httpPoolCase) return runPool();

  const options = httpMode === "echo" ? {
    method: "POST", body: '{"value":"世界\\u0000"}',
    headers: { "Content-Type": "application/json", Authorization: "Bearer test", "User-Agent": "yuke-test", "Accept-Encoding": "gzip" },
  } : httpMode === "head" ? { method: "HEAD" } : Object.create(null);
  if (["put", "patch", "delete"].includes(httpMode)) options.method = httpMode.toUpperCase();
  // Repeat a block to avoid the per-character fill loop in QuickJS.
  if (httpMode === "upload_stall") { options.method = "POST"; options.body = "x".repeat(1024).repeat(16 * 1024); }
  options.timeoutMs = ["stall", "partial_head", "slow_body", "upload_stall"].includes(httpMode) ? 50 : 2000;
  if (failures[httpMode]) {
    try { await fetch(httpUrl, options); } catch (error) { equal(error.message, failures[httpMode]); return; }
    throw new Error("request did not reject: " + httpMode);
  }
  // A chunk read has no total cap, so the body that `text()` refuses streams whole.
  if (httpMode === "oversize") {
    let total = 0, chunks = 0;
    for await (const chunk of (await fetch(httpUrl, options)).body) { total += chunk.length; chunks += 1; }
    equal(total, 256 * 1024 + 1);
    check("the body arrived in bounded chunks", chunks >= 5);
    return;
  }
  if (bodyFailures[httpMode]) {
    const response = await fetch(httpUrl, options);
    equal(response.status, 200);
    try { await response.text(); } catch (error) { equal(error.message, bodyFailures[httpMode]); return; }
    throw new Error("body did not reject: " + httpMode);
  }
  const expectedBody = options.body;
  const pending = fetch(httpUrl, options);
  if (httpMode === "echo") { options.body = "changed"; options.headers.Authorization = "changed"; }
  const response = await pending;
  equal(response.status, httpMode === "missing" ? 404 : httpMode === "empty" ? 204 : 200);
  equal(response.ok, httpMode !== "missing");
  equal(response.headers.get("missing"), null);
  equal(response.headers.get("toString"), null);
  equal(response.headers.get(1), null);
  const text = await response.text();
  equal(await response.text(), text);
  equal(await response.body.read(), null);
  equal(await response.body.readAll(), "");
  if (httpMode === "reply") equal((await response.json()).ok, true);
  if (httpMode === "echo") {
    equal(text, expectedBody);
    equal((await response.json()).value, "世界\0");
    equal(response.headers.get("X-NAME"), "first");
    equal(response.headers.get("__proto__"), "safe");
  }
  if (httpMode === "head" || httpMode === "empty") equal(text, "");
  if (["put", "patch", "delete", "hints", "close_delimited"].includes(httpMode)) equal(text, "ok");
  if (httpMode === "missing") equal((await response.json()).error, "missing");
  if (["limit", "chunk_limit", "close_limit"].includes(httpMode)) equal(text, "x".repeat(256 * 1024));
  if (httpMode === "chunked") {
    equal(text, "a\0bcd");
    const parsed = response.json();
    check("json rejects asynchronously", parsed instanceof Promise);
    let rejected = false;
    try { await parsed; } catch (error) { rejected = error instanceof SyntaxError; }
    check("invalid JSON rejects with SyntaxError", rejected);
  }
  if (httpMode === "headers_limit") {
    equal(text, "ok");
    equal(response.headers.get("x-62"), "value");
    equal(response.headers.get("x-63"), null);
  }
  if (httpMode === "header_bytes_limit") {
    equal(text, "ok");
    equal(response.headers.get("x-large").length, 8170);
  }
  if (httpMode === "utf8") {
    equal(text, "a\ufffd\0b");
    equal(response.headers.get("x-bytes"), "a\ufffdb");
  }
}
run().then(() => { globalThis.httpDone = true; }, error => { globalThis.httpError = httpMode + ": " + error.message + "\n" + error.stack; globalThis.httpDone = true; });
