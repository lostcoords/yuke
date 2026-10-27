// The web classes `Request` and `Response`, and their body methods. Many cases follow the web platform tests (WPT) of
// `fetch/api/request`, `fetch/api/response`, and `fetch/api/body`.

import { assert, equal, test } from "yuke:test";
import { rejectedName, thrownNames } from "./errors.ts";

/** The getter of the accessor `name` of `prototype`. */
function getter(prototype: object, name: string): () => unknown {
  const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
  assert(descriptor?.get !== undefined, `${name} is an accessor`);
  return descriptor.get;
}

test("a request has the defaults of the standard", () => {
  const request = new Request(new URL("https://a.example/x?q#f"));
  equal(
    [
      request.method,
      request.url,
      request.redirect,
      request.body,
      request.bodyUsed,
      Object.getPrototypeOf(request.signal) === AbortSignal.prototype,
      request.signal.aborted,
      request.headers instanceof Headers,
      [...request.headers],
    ],
    ["GET", "https://a.example/x?q#f", "follow", null, false, true, false, true, []],
  );
});

test("a request normalizes the method and refuses bad input", () => {
  const url = "https://a.example/";
  equal(new Request(url, { method: "post" }).method, "POST");
  equal(new Request(url, { method: "patch" }).method, "patch");
  equal(
    thrownNames([
      () => new Request(url, { method: "connect" }),
      () => new Request(url, { method: "bad method" }),
      () => new Request(url, { body: "x" }),
      () => new Request(url, { method: "HEAD", body: "x" }),
      () => new Request("/relative"),
      () => new Request("https://user:pw@a.example/"),
      // @ts-expect-error: a redirect is `follow`, `error`, or `manual`.
      () => new Request(url, { redirect: "sometimes" }),
      // @ts-expect-error: a signal is an AbortSignal.
      () => new Request(url, { signal: {} }),
      // @ts-expect-error: only a response takes a stream body.
      () => new Request(url, { method: "POST", body: new ReadableStream() }),
      // @ts-expect-error: only `half` is a valid duplex.
      () => new Request(url, { method: "POST", body: "x", duplex: "full" }),
      // @ts-expect-error: a request takes an input.
      () => new Request(),
    ]),
    new Array<string>(11).fill("TypeError"),
  );
});

test("a request body sets its content type and reads once", async () => {
  const url = "https://a.example/";
  const type = (init: RequestInit) => new Request(url, { method: "POST", ...init }).headers.get("content-type");
  class Params extends URLSearchParams {
    override toString() {
      return "wrong";
    }
  }
  const request = new Request(url, { method: "POST", body: "hé" });
  const text = await request.text();
  equal(
    [
      type({ body: "x" }),
      type({ body: new URLSearchParams("a=1") }),
      type({ body: new Uint8Array([1]) }),
      type({ body: "x", headers: { "content-type": "application/json" } }),
    ],
    ["text/plain;charset=UTF-8", "application/x-www-form-urlencoded;charset=UTF-8", null, "application/json"],
  );
  equal([text, request.bodyUsed], ["hé", true]);
  equal(await rejectedName(request.text()), "TypeError");
  equal(await new Request(url, { method: "PUT", body: new URLSearchParams({ a: "b c" }) }).text(), "a=b+c");
  equal(await new Request(url, { method: "PUT", body: new Params("a=1") }).text(), "a=1");
});

test("a request from a request copies it and takes its body", async () => {
  const original = new Request("https://a.example/", { method: "POST", body: "data", headers: { a: "1" } });
  const copy = new Request(original, { method: "PUT" });
  copy.headers.append("b", "2");
  equal(
    [copy.url, copy.method, original.method, original.headers.has("b"), copy.headers.get("a"), original.bodyUsed],
    ["https://a.example/", "PUT", "POST", false, "1", true],
  );
  equal(await copy.text(), "data");
  equal(await rejectedName(original.text()), "TypeError");
  equal(thrownNames([() => new Request(original)]), ["TypeError"]);
  equal(new Request(new Request("https://a.example/", { redirect: "manual" })).redirect, "manual");
});

test("the signal of a request follows the signal of its init and its input", () => {
  const controller = new AbortController();
  const request = new Request("https://a.example/", { signal: controller.signal });
  const copy = new Request(request);
  const unlinked = new Request(request, { signal: null });
  equal(request.signal.aborted, false);
  controller.abort("stop");
  equal(
    [request.signal === controller.signal, request.signal.reason, copy.signal.reason, unlinked.signal.aborted],
    [false, "stop", "stop", false],
  );
});

test("a response has the defaults of the standard and takes its init", async () => {
  const plain = new Response();
  const made = new Response("hi", { status: 201, statusText: "Created", headers: { "x-a": "1" } });
  equal(
    [plain.status, plain.ok, plain.statusText, plain.type, plain.url, plain.redirected, plain.body, await plain.text()],
    [200, true, "", "default", "", false, null, ""],
  );
  equal(
    [made.status, made.statusText, made.headers.get("x-a"), made.headers.get("content-type"), await made.text()],
    [201, "Created", "1", "text/plain;charset=UTF-8", "hi"],
  );
});

test("a response checks its status and status text", () => {
  equal(
    thrownNames([
      () => new Response(null, { status: 199 }),
      () => new Response(null, { status: 600 }),
      () => new Response(null, { statusText: "a\nb" }),
      () => new Response("x", { status: 204 }),
      // @ts-expect-error: a status is a number.
      () => new Response(null, { status: 1n }),
    ]),
    ["RangeError", "RangeError", "TypeError", "TypeError", "TypeError"],
  );
  equal(
    [
      new Response(null, { status: 65_736 }).status,
      new Response(null, { status: 204 }).status,
      new Response(null, { status: 599 }).ok,
    ],
    [200, 204, false],
  );
});

test("the body methods read the bytes once", async () => {
  const bytes = new Uint8Array([0xef, 0xbb, 0xbf, 0x61, 0xff]);
  const json = await new Response('{"a":[1]}').json();
  const buffer = await new Response(bytes).arrayBuffer();
  const kept = new Response(bytes);
  bytes[3] = 0x62;
  const viewed = await new Response(bytes.subarray(3)).bytes();
  const used = new Response("x");
  await used.text();
  const locked = new Response("x");
  assert(locked.body !== null);
  locked.body.getReader();
  const cancelled = new Response("x");
  assert(cancelled.body !== null);
  await cancelled.body.cancel();
  equal(json, { a: [1] });
  assert(buffer instanceof ArrayBuffer);
  equal(buffer.byteLength, 5);
  equal(new Uint8Array(await kept.arrayBuffer())[3], 97);
  equal(await new Response(new Uint8Array([0xef, 0xbb, 0xbf, 0x61, 0xff])).text(), "a�");
  equal(viewed, new Uint8Array([98, 255]));
  equal(
    [used.bodyUsed, await rejectedName(used.text()), await rejectedName(used.arrayBuffer())],
    [true, "TypeError", "TypeError"],
  );
  equal([locked.bodyUsed, await rejectedName(locked.text())], [false, "TypeError"]);
  equal([cancelled.bodyUsed, await rejectedName(cancelled.text())], [true, "TypeError"]);
  equal(await rejectedName(new Response("{").json()), "SyntaxError");
});

test("a response reads a stream body and refuses a chunk that is not bytes", async () => {
  const stream = <T>(chunks: T[]) =>
    new ReadableStream<T>({
      start(controller) {
        for (const chunk of chunks) controller.enqueue(chunk);
        controller.close();
      },
    });
  const encoder = new TextEncoder();
  const body = stream([encoder.encode("a"), encoder.encode("b")]);
  // The source writes each chunk into one buffer, so the body must keep a copy of each chunk.
  const buffer = new Uint8Array(1);
  let pulls = 0;
  const reused = new ReadableStream<Uint8Array>(
    {
      pull(controller) {
        if (pulls === 2) controller.close();
        else {
          buffer[0] = 0x61 + pulls++;
          controller.enqueue(buffer);
        }
      },
    },
    { highWaterMark: 0 },
  );
  const response = new Response(body);
  const locked = new ReadableStream<Uint8Array>();
  locked.getReader();
  equal([response.body === body, response.headers.has("content-type"), await response.text()], [true, false, "ab"]);
  equal(await new Response(reused).text(), "ab");
  // @ts-expect-error: a chunk of a body is bytes.
  equal(await rejectedName(new Response(stream(["text"])).text()), "TypeError");
  equal(thrownNames([() => new Response(locked)]), ["TypeError"]);
});

test("the static methods make an error, a redirect, and JSON", async () => {
  const error = Response.error();
  const redirect = Response.redirect("https://a.example/x", 307);
  const json = Response.json({ a: 1 }, { status: 201, headers: { "content-type": "text/x" } });
  equal([error.type, error.status, error.ok, error.body], ["error", 0, false, null]);
  equal(
    [redirect.status, redirect.headers.get("location"), Response.redirect("https://a.example/").status],
    [307, "https://a.example/x", 302],
  );
  equal([json.status, json.headers.get("content-type"), await json.text()], [201, "text/x", '{"a":1}']);
  equal(Response.json("x").headers.get("content-type"), "application/json");
  equal(
    thrownNames([
      () => Response.redirect("https://a.example/", 200),
      () => Response.redirect("/relative"),
      () => Response.json(undefined),
      () => Response.json({ a: 1n }),
    ]),
    ["RangeError", "TypeError", "TypeError", "TypeError"],
  );
});

test("a member refuses a value of another class", async () => {
  equal(
    thrownNames([
      () => getter(Request.prototype, "url").call({}),
      () => getter(Response.prototype, "body").call({}),
      () => getter(Request.prototype, "bodyUsed").call({}),
    ]),
    ["TypeError", "TypeError", "TypeError"],
  );
  equal(await rejectedName(Response.prototype.text.call({})), "TypeError");
  equal(await rejectedName(Request.prototype.json.call(new Response("1"))), "TypeError");
  equal(
    [new Request("https://a.example/"), new Response()].map((value) => Object.prototype.toString.call(value)),
    ["[object Request]", "[object Response]"],
  );
  assert(Object.keys(Response.prototype).includes("text"));
});

test("the arguments convert before the steps run", () => {
  const seen: string[] = [];
  const init = {
    get body() {
      seen.push("body");
      return null;
    },
    get headers() {
      seen.push("headers");
      return undefined;
    },
    get method() {
      seen.push("method");
      return undefined;
    },
  };
  const status = {
    valueOf() {
      seen.push("status");
      return 301;
    },
  };
  equal(
    thrownNames([
      // @ts-expect-error: the init gives `undefined` from its getters to test the order of the conversions.
      () => new Request("/relative", init),
      // @ts-expect-error: the status converts to a number through `valueOf`.
      () => Response.redirect("/relative", status),
    ]),
    ["TypeError", "TypeError"],
  );
  equal(seen, ["body", "headers", "method", "status"]);
});
