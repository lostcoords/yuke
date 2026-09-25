import { fetch } from "yuke";
import { check, equal } from "yuke:internal/test";
import * as cancellation from "yuke:internal/native/cancellation";

async function refuses(args, message) {
  const result = fetch(...args);
  check("fetch always returns a promise", result instanceof Promise);
  try { await result; } catch (error) { equal(error.message, message); return; }
  throw new Error("request did not reject: " + message);
}

async function run() {
  const url = "http://127.0.0.1:1/";
  for (const value of [undefined, null, 42, {}, new String(url)]) await refuses([value], "the url must be a string");
  for (const value of ["", " ", "/relative", "ftp://host/", "http:", "http:///", "http://a\r\nx", "http://a/\0", "http://a b/", "http://user:pass@host/"]) {
    await refuses([value], "the url is invalid");
  }
  for (const value of [null, 1, "", [], () => {}, new Date(), Object.create({}), Object.setPrototypeOf([], null)]) {
    await refuses([url, value], "the fetch options must be an object");
  }
  // A null option is an absent option, as in every native module.
  for (const method of [0, "get", "OPTIONS", "CONNECT", "TRACE", "bad"]) await refuses([url, { method }], "the method must be GET, POST, PUT, PATCH, HEAD, or DELETE");
  for (const method of ["GET", "HEAD", "DELETE"]) await refuses([url, { method, body: "" }], "this method must not have a body");
  for (const body of [0, {}, new Uint8Array(2)]) await refuses([url, { method: "POST", body }], "the body must be a string");
  for (const timeoutMs of [0, -1, 0.5, NaN, Infinity, 600001, "1"]) await refuses([url, { timeoutMs }], "a fetch option is invalid");
  for (const headers of [null, [], 1, "", new Date(), Object.create({})]) await refuses([url, { headers }], "headers must be an object");
  for (const headers of [{ "": "x" }, { "bad:name": "x" }, { "bad name": "x" }, { "a\0b": "x" }, { a: "x\r\ny" }, { a: "\x01" }, { a: 1 }, { a: null }, { A: "1", a: "2" }, { Host: "x" }, { Connection: "close" }, { "Content-Length": "0" }, { "Transfer-Encoding": "chunked" }]) {
    await refuses([url, { headers }], "a request header is invalid");
  }
  for (const options of [{ redirect: "follow" }, { redirect: undefined }, { query: {} }, { typo: true }]) await refuses([url, options], "a fetch option is not supported");
  for (const signal of [null, {}, { aborted: false }, 1]) await refuses([url, { signal }], "a fetch option is invalid");
  await refuses([url, { get signal() { throw new Error("getter"); } }], "a fetch option is invalid");
  await refuses([url, { headers: { get a() { throw new Error("getter"); } } }], "a request header is invalid");
  await refuses([url, { get method() { throw new Error("getter"); } }], "the method must be GET, POST, PUT, PATCH, HEAD, or DELETE");
  const stopped = cancellation.create();
  cancellation.cancel(stopped);
  await refuses([url, { signal: stopped }], "the operation was canceled");
  await cancellation.drain(stopped);
  globalThis.httpDone = true;
}
run().catch(error => { globalThis.httpError = error.message + "\n" + error.stack; globalThis.httpDone = true; });
