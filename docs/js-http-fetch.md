# JavaScript HTTP fetch and env lookup

Status: Not implemented. This document is the implementation spec.

Date: 2026-09-11

An agent that implements this work must follow this file. Do not invent extra API surface.
Do not edit `~/.config/yuke`. Do not rewrite the user's `web_search` plugin in this pass.

## Goal

Config plugins today shell out to `curl` through `yuke:exec` because the Zig→JS host has no HTTP primitive and no process-env primitive.

See `~/.config/yuke/tools/web_search.js` for the motivating caller: GET with a custom header, POST with a JSON body, `timeoutMs`, tool `signal`, and `BRAVE_API_KEY` / `TAVILY_API_KEY` from the process environment (with a `.env` file fallback that `yuke:fs` can already read).

This work adds:

1. `import { fetch } from "yuke:http"` — a trimmed, Node-like `fetch`.
2. `import { env } from "yuke:env"` — a synchronous process-env lookup.

After this lands, a plugin can drop curl. Rewriting that plugin is out of scope here.

## Accepted decisions

1. One HTTP entry point: `fetch`. No `request()`, no `get`/`post` helpers.
2. `fetch` is a baked JS module over a native module, same split as `yuke:interaction` / `yuke:interaction-native`.
3. `timeoutMs` lives on the init object. Do not add `AbortController`, `AbortSignal.timeout`, or `setTimeout`.
4. `signal` is the existing tool `{ aborted: boolean }` object. Same identity check as `yuke:exec`. It is not WHATWG AbortSignal.
5. 3xx rejects. Do not follow redirects. Do not take a `redirect` option.
6. Network / timeout / cancel / oversize / bad URL / 3xx reject with `Error`. HTTP 4xx/5xx resolve. `res.ok` is false. This is fetch, not curl `--fail`.
7. Body cap is 256 KiB (`src/net/http.zig` `max_oauth_response_bytes`). Oversize rejects. Do not truncate.
8. Do not JSON-escape the response body. Extend `pending.Result` with an `.http` variant. The owner builds a JS object with `newString`.
9. Each call owns a fresh `std.http.Client`. `keep_alive = false`. No process-wide pool.
10. `env.get` is synchronous. It is a map read, not I/O. Missing key returns `undefined`. Bad argument throws TypeError.
11. Query strings stay in JS (`encodeURIComponent`). No `query:` init field.
12. Do not reuse `src/net/http.zig`. That client is POST-only and classifies OAuth PreFlight/Ambiguous.
13. Do not import `lib/ai/instance.zig` from the JS host. Copy the RFC 9110 header-name/value checks into the HTTP native module.

## Public API

```js
import { fetch } from "yuke:http";
import { env } from "yuke:env";

const res = await fetch(url, {
  method: "POST",
  headers: { "Content-Type": "application/json", Authorization: "Bearer x" },
  body: JSON.stringify({ q: "hi" }),
  timeoutMs: 15_000,
  signal,
});

res.status;                          // number
res.ok;                              // status >= 200 && status <= 299
res.headers.get("content-type");     // string | null, case-insensitive
await res.text();                    // Promise<string>
await res.json();                    // Promise<any>, JSON.parse of the same string

env.get("BRAVE_API_KEY");            // string | undefined
```

`fetch(url)` with no init is valid (GET, default timeout, no headers, no body, no signal).

### Fetch rules

| Input | Rule |
|---|---|
| `url` | Absolute `http:` or `https:` string. Relative, empty, non-string, or another scheme rejects. |
| `method` | `GET` `POST` `PUT` `PATCH` `HEAD` `DELETE`. Default `GET`. Case-sensitive uppercase. Other names reject. |
| `headers` | Plain object, string values only. Arrays reject. Missing/`undefined` init.headers is empty. |
| `body` | String or absent. `GET`/`HEAD`/`DELETE` plus body rejects (`std.http.Method.requestHasBody` is false for those). `POST`/`PUT`/`PATCH` with no body send an empty body. |
| `timeoutMs` | Whole number of milliseconds in `[1, 120000]`. Default `30000`. Fraction, NaN, 0, or above max rejects. |
| `signal` | Absent, or the live tool signal. Forged/stale rejects with the exec message. |
| `redirect` | Do not read this field. Behavior is always refuse. |

Header name/value checks (copy from `lib/ai/instance.zig`):

- Name: nonempty RFC 9110 `tchar` token. Empty, colon, space, CR/LF reject.
- Value: no control byte except tab. CR/LF reject.
- `Host` and `Connection` from JS reject (the client sets these).
- `Accept-Encoding` from JS is ignored. The client always sets `accept_encoding = .omit` so the body is uncompressed.
- Duplicate JS keys cannot exist on a plain object. Duplicate names that differ only by case: last enumerated name wins; reject if you already stored a case-insensitive duplicate, same as `validHeaders` in `instance.zig`.

### Response rules

The public object is a JS `Response` instance from `src/js/app/http.js`.

- `status` — `u16` from the status line.
- `ok` — `status >= 200 && status <= 299`.
- `headers.get(name)` — lowercase lookup on the native header map. Non-string name returns `null`. Missing returns `null`.
- `text()` — `Promise.resolve(this._body)`.
- `json()` — `Promise.resolve(JSON.parse(this._body))`. Bad JSON rejects that promise with a SyntaxError, like `JSON.parse`.
- Calling both `text()` and `json()` is allowed. No `bodyUsed`.

Do not implement: `statusText`, `url`, `redirected`, `clone`, `arrayBuffer`, `body` as a stream, Request, FormData, Blob, global `fetch`.

### Error messages

Argument refusals reject the `fetch` promise (settled Error, same as `exec`). Exact strings, closed set:

| Condition | `e.message` |
|---|---|
| Host not `.open` | `the host is closed` |
| Missing url | `fetch needs a url` |
| url not a string | `the url must be a string` |
| url empty/whitespace or not absolute http(s) | `the url is invalid` |
| method not an allowed string | `the method must be GET, POST, PUT, PATCH, HEAD, or DELETE` |
| GET/HEAD/DELETE + body | `this method must not have a body` |
| body present and not a string | `the body must be a string` |
| headers not a plain object | `headers must be an object` |
| header name invalid / Host / Connection | `a request header is invalid` |
| header value not a string or has a control byte | `a request header is invalid` |
| duplicate header names (case-insensitive) | `a request header is invalid` |
| `timeoutMs` not a whole number in range | `timeoutMs must be a whole number of milliseconds up to 120000` |
| forged/stale signal | `the fetch signal does not belong to an active tool call` |
| signal property unreadable | `the fetch signal could not be read` |
| init present and not a plain object | `the fetch options must be an object` |

Task / transport failures (also `Error.message`):

| Condition | `e.message` |
|---|---|
| Tool cancel or `io.checkCancel` | `the request was canceled` |
| Supervisor deadline | `the request timed out` |
| Cannot spawn worker | `the host cannot start another operation` |
| 3xx or `error.TooManyHttpRedirects` | `the request was redirected` |
| Body larger than 256 KiB | `the response exceeds the size limit` |
| `error.UnsupportedUriScheme`, `error.UriMissingHost`, `std.Uri.parse` fail | `the url is invalid` |
| Every other `std.http` / TLS / DNS / connect / read failure | `the host could not complete the request` |

Never leak `error.Name` or a Zig `@errorName` into JavaScript.

`env.get`:

| Condition | Behavior |
|---|---|
| Host not `.open` | throw TypeError `the host is closed` |
| name not a nonempty string | throw TypeError `the name must be a nonempty string` |
| key absent | return `undefined` (not a throw, not a Promise) |
| key present | return a string (UTF-8 sanitized) |

## Files to add

| Path | Role |
|---|---|
| `src/js/native/http.zig` | Native `yuke:http-native`. `export fn install`. Parse, task, `std.http.Client`. |
| `src/js/native/env.zig` | Native `yuke:env`. `env.get`. |
| `src/js/app/http.js` | Baked `yuke:http`. Response + Headers classes. |
| `src/js/app/types/http-native.d.ts` | Types for the native raw result. |
| `src/js/app/types/http.d.ts` | Types for public `fetch` / Response. Prefer this if JSDoc on `http.js` is not enough for `tsc`. |
| `src/js/app/types/env.d.ts` | Types for `yuke:env`. |
| `src/js/tests/native_tools/http-refuse.test.js` | Argument refusals. |
| `src/js/tests/native_tools/http.test.js` | Loopback GET/POST/404/HEAD/headers. |
| `src/js/tests/native_tools/http-redirect.test.js` | 302 rejects. |
| `src/js/tests/native_tools/http-oversize.test.js` | Body cap. |
| `src/js/tests/native_tools/http-timeout.test.js` | Stall past `timeoutMs`. |
| `src/js/tests/native_tools/http-signal.test.js` | Tool signal, copy `exec-signal.test.js`. |
| `src/js/tests/native_tools/env.test.js` | `env.get`. |

Split JS HTTP cases so each Zig test owns one server mode. One-shot servers are easier than a multiplexed fixture.

## Files to edit

| Path | Change |
|---|---|
| `src/js/pending.zig` | Add `Result.http`. Settle with `newObject`/`newString`. Free owned slices. |
| `src/js/host.zig` | Import and `install` both native modules. Add `"http"` to `default_baked`. |
| `src/js/native_tools_test.zig` | Zig tests that create the host, the loopback server, and pump. |

Do not change `lib/proto/`, `schema/proto.json`, or the engine.

## Architecture

```
plugin
  import { fetch } from "yuke:http"          baked JS
    import { fetch as send } from "yuke:http-native"
      jsFetch copies args, startTaskWithSignal
        httpTask (supervisor, may cancel)
          httpWorker (std.http.Client, no QuickJS)
            op.finish(.{ .http = ... }) or .{ .failed = ... }
        owner ops.settle builds { status, body, headers }
    then (raw) => new Response(raw)
```

A task never touches JavaScript. That is the `pending.zig` rule. Copy `src/js/native/exec.zig`.

`yuke:http-native` is undocumented. Tests and `http.js` may import it. Plugins must import `yuke:http`.

## 1. `pending.Result.http`

File: `src/js/pending.zig`

Current variants: `text`, `json`, `boolean`, `undefined`, `failed`.

Add:

```zig
pub const HttpHeader = struct {
    name: []u8,
    value: []u8,
};

pub const Http = struct {
    status: u16,
    body: []u8,
    headers: []HttpHeader,
};

pub const Result = union(enum) {
    text: []u8,
    json: [:0]u8,
    http: Http,
    boolean: bool,
    undefined,
    failed: Failure,
};
```

`freeResult` for `.http`:

1. Free `body`.
2. For each header, free `name` and `value`.
3. Free the `headers` slice.

`call` (settle) for `.http`:

1. `obj = ctx.newObject()`.
2. `module.set(ctx, obj, "status", ctx.newInt32(status))`.
3. `module.set(ctx, obj, "body", ctx.newString(body))`.
4. `headers_obj = ctx.newObject()`. For each header, `module.set` the lowercase name to `newString(value)`. First name wins if a duplicate slipped through.
5. `module.set(ctx, obj, "headers", headers_obj)`.
6. If `ctx.hasException()`, free `obj` and take the exception path already used for a failed conversion.
7. Resolve with `obj`.

Do not `parseJSON` the HTTP body. `Result.json` JSON-escapes `exec` stdout. That path would duplicate the body and is forbidden here.

`status` fits in `i32`. Do not use `newInt64` unless you prefer consistency with other modules; `newInt32` is enough for HTTP status.

## 2. Native `yuke:http-native`

New file: `src/js/native/http.zig`.

Install:

```zig
pub fn install(host: *Host) void {
    module.installFunctions(host, "yuke:http-native", &.{
        .{ .name = "fetch", .arity = 2, .call = jsFetch },
    });
}
```

Constants:

```zig
pub const default_timeout_ms: u32 = 30_000;
pub const max_timeout_ms: u32 = 120_000;
pub const max_response_bytes: u32 = 256 * 1024;
pub const max_response_headers: u32 = 64;
pub const max_response_header_bytes: u32 = 8 * 1024;
```

Copy header validation (tchar / no CR LF) into this file as private functions. One-line comments. Do not import AI instance types.

### Owned request

```zig
const Header = struct { name: []u8, value: []u8 };

const Request = struct {
    url: []u8,
    method: std.http.Method,
    headers: []Header,          // extra_headers; well-known stripped out
    content_type: ?[]u8,
    authorization: ?[]u8,
    user_agent: ?[]u8,
    body: ?[]u8,
    timeout_ms: u32,

    fn parse(...) ParseError!Request
    fn free(self: Request, gpa: std.mem.Allocator) void
};
```

`free` must free url, every header, optional strings, body, and the headers slice.

Parse `init` with `getPropertyStr`, same style as `exec.zig` `timeoutOf` / `optionalString`.

Method map:

```
GET -> .GET, POST -> .POST, PUT -> .PUT, PATCH -> .PATCH, HEAD -> .HEAD, DELETE -> .DELETE
```

Default method when init.method is undefined: `.GET`.

URL checks after copy:

1. Trim is not required if you reject empty. Reject length 0.
2. `std.Uri.parse(url)` must succeed.
3. Scheme must be `http` or `https` (compare with `std.ascii.eqlIgnoreCase` on `uri.scheme`).
4. Host must be present (`error.UriMissingHost` / empty host → invalid url).

Iterate JS headers with `ctx.getOwnPropertyNames(headers_obj, .{ .strings = true, .enum_only = true })`. Free the table with `ctx.freePropertyEnum`. Convert each atom to a string. Skip `signal`, `method`, `body`, `timeoutMs` — those are on init, not on headers.

For each header name:

- `host` / `connection` (case-insensitive) → parse error.
- `accept-encoding` → skip (do not store).
- `content-type` / `authorization` / `user-agent` → store on the matching optional field; reject a second case-insensitive duplicate.
- else → append to `headers`. Reject case-insensitive duplicate against extras and against the well-known optionals.

`std.http.Client.request` asserts no `:` in extra header names and no `\r\n` in names/values. The RFC checks must run before the task starts, because an assertion crash is a host bug.

### `jsFetch`

Copy `jsExec` in `src/js/native/exec.zig`:

1. Phase `.open` or reject `the host is closed`.
2. Need a url argument.
3. Read `signal` from options if options is an object.
4. Validate signal with `host.calls.acceptsSignal`.
5. `Request.parse` or reject with the closed message set.
6. `return host.startTaskWithSignal(Request, httpTask, request, signal)`.

### Supervisor `httpTask`

Copy `execTask`, then add a deadline. `Cancel.runChild` returns void-ish `ChildResult` and cannot carry `pending.Result`. Do not use it. Duplicate the exec join, with `waitTimeout`:

```
defer req.free(host.gpa);
if (op.cancel.requested) return op.finish(.{ .failed = .{ .message = "the request was canceled" } });
var worker = host.io.concurrent(httpWorker, .{ host, op, req }) catch
    return op.finish(.{ .failed = .{ .message = "the host cannot start another operation" } });

const timeout: std.Io.Timeout = .{ .duration = .{ .clock = .awake, .raw = .fromMilliseconds(req.timeout_ms) } };
op.cancel.event.waitTimeout(host.io, timeout) catch |err| {
    const result = worker.cancel(host.io);
    if (err == error.Timeout) {
        freeIfHttp(host.gpa, result);
        op.finish(.{ .failed = .{ .message = "the request timed out" } });
        return;
    }
    op.finish(result); // canceled / aborted
    return;
};
const result = if (op.cancel.requested) worker.cancel(host.io) else worker.await(host.io);
op.finish(result);
```

`freeIfHttp` must free a `.http` payload when the supervisor replaces it with a timeout/cancel failure. Otherwise a racy completed worker leaks.

`httpWorker` must `defer op.cancel.finish(host.io)` so the supervisor wakes when the request ends before the deadline.

### Worker `httpWorker`

No QuickJS. Pattern for the HTTP exchange: `src/net/http.zig` `sendGrant` and `lib/ai/transport/http.zig` `open`.

```
defer op.cancel.finish(host.io);
if (op.cancel.requested) return canceled;
host.io.checkCancel() catch return canceled;

var client: std.http.Client = .{ .allocator = host.gpa, .io = host.io };
defer client.deinit();

const uri = std.Uri.parse(req.url) catch return invalid_url;

var request = client.request(req.method, uri, .{
    .redirect_behavior = .not_allowed,
    .keep_alive = false,
    .headers = .{
        .accept_encoding = .omit,
        .content_type = if (req.content_type) |v| .{ .override = v } else .default,
        .authorization = if (req.authorization) |v| .{ .override = v } else .default,
        .user_agent = if (req.user_agent) |v| .{ .override = v } else .default,
    },
    .extra_headers = extra, // []const std.http.Header from req.headers
}) catch |err| return mapConnect(err);

errdefer {
    if (request.connection) |c| c.closing = true;
    request.deinit();
}
defer request.deinit();

switch (req.method) {
    .GET, .HEAD, .DELETE => try request.sendBodiless(),
    else => try request.sendBodyComplete(req.body orelse &[_]u8{}),
}

var response = request.receiveHead(&.{}) catch |err| return mapHead(err);

const status = @intFromEnum(response.head.status);
if (status >= 300 and status <= 399)
    return fail("the request was redirected");

// Copy response headers NOW. response.reader() invalidates head string slices.
// See lib/ai/transport/http.zig: "The reader below invalidates these slices."

const headers = copyResponseHeaders(host.gpa, response.head) catch ...;

var body_buf = try host.gpa.alloc(u8, max_response_bytes);
errdefer host.gpa.free(body_buf);
var transfer: [4096]u8 = undefined;
var writer: std.Io.Writer = .fixed(body_buf);
_ = response.reader(&transfer).streamRemaining(&writer) catch |err| switch (err) {
    error.WriteFailed => return fail oversize,
    else => return fail complete,
};
const raw_body = writer.buffered();
const body = utf8.sanitize(host.gpa, raw_body) catch unreachable;
host.gpa.free(body_buf); // if sanitize copied; if you sanitize into a new alloc, free the cap buffer

return .{ .http = .{ .status = status, .body = body, .headers = headers } };
```

`copyResponseHeaders`:

- `var it = response.head.iterateHeaders();`
- For each header, lowercase the name into an owned buffer (`std.ascii.lowerString`).
- Skip if that lowercase name is already in the list (first wins).
- Stop when `headers.len == 64` or accumulated name+value bytes would exceed 8 KiB. Drop the rest. Do not fail the request.
- Values: copy as received, then `utf8.sanitize` (or sanitize on the concatenated copies). Invalid UTF-8 in a header value must not crash `newString`.

`mapConnect` / `mapHead`:

- `error.UnsupportedUriScheme`, `error.UriMissingHost` → `the url is invalid`
- `error.TooManyHttpRedirects` → `the request was redirected`
- `error.Canceled` → `the request was canceled`
- `error.WriteFailed` after a full fixed buffer → `the response exceeds the size limit`
- else → `the host could not complete the request`

HEAD: `Method.responseHasBody` is false. `streamRemaining` should yield an empty body. Tests accept empty or short.

Mark `connection.closing = true` on any mid-request failure so the pool never reuses a dirty connection (`keep_alive` is already false).

Do not follow redirects even if `receiveHead` returns 302 without error. Check status 300–399 after a successful head.

## 3. Baked `yuke:http`

New file: `src/js/app/http.js`.

Add `"http"` to `Host.default_baked` in `src/js/host.zig` (the names tuple). Placement: next to other non-UI modules is fine (`"client"` area). The loader maps `"http"` to `yuke:http` and `@embedFile("app/http.js")`.

```js
// yuke:http — bounded fetch over yuke:http-native.
import { fetch as send } from "yuke:http-native";

class Headers {
  constructor(map) {
    this._map = map;
  }
  get(name) {
    if (typeof name !== "string") return null;
    const value = this._map[name.toLowerCase()];
    return value === undefined ? null : value;
  }
}

class Response {
  constructor(raw) {
    this.status = raw.status;
    this.ok = raw.status >= 200 && raw.status <= 299;
    this.headers = new Headers(raw.headers);
    this._body = raw.body;
  }
  text() {
    return Promise.resolve(this._body);
  }
  json() {
    return Promise.resolve(JSON.parse(this._body));
  }
}

/** @param {string} url @param {object} [init] @returns {Promise<Response>} */
export function fetch(url, init) {
  return send(url, init).then((raw) => new Response(raw));
}
```

Keep comments to one line. JSDoc is enough for `tsc` if `http.js` is in `src/js/app/tsconfig.json` include (it is: `./**/*.js`).

Still add declaration files so `import { fetch } from "yuke:http"` type-checks from other files. `paths` maps `yuke:*` to `./*.js`, so `yuke:http` resolves to `http.js`. A separate `types/http.d.ts` `declare module "yuke:http"` can fight that path. Prefer JSDoc exports on `http.js` plus `types/http-native.d.ts` for the native module (native modules have no `.js` file).

`src/js/app/types/http-native.d.ts`:

```ts
declare module "yuke:http-native" {
  interface RawResponse {
    status: number;
    body: string;
    headers: Record<string, string>;
  }
  interface FetchInit {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
    timeoutMs?: number;
    signal?: { aborted: boolean };
  }
  export function fetch(url: string, init?: FetchInit): Promise<RawResponse>;
}
```

`src/js/app/types/env.d.ts`:

```ts
declare module "yuke:env" {
  export const env: {
    get(name: string): string | undefined;
  };
}
```

If `tsc` reports that `yuke:http` has no types, add `types/http.d.ts` with `declare module "yuke:http"` matching the public API. Do not declare both a path mapping and a conflicting module if `tsc` already sees `http.js`.

Run `mise run check-ts` after the JS files exist.

## 4. Native `yuke:env`

New file: `src/js/native/env.zig`.

```zig
pub fn install(host: *Host) void {
    module.installObject(host, "yuke:env", "env", &.{
        .{ .name = "get", .arity = 1, .call = jsGet },
    }, null);
}
```

`jsGet` is synchronous. Do not return a Promise.

- If `host.phase != .open`, `return ctx.throwTypeError("the host is closed")`.
- Name from `module.string`. Non-string or empty → `throwTypeError("the name must be a nonempty string")`.
- `host.execution.env.get(name)` → if null, return `quickjs.UNDEFINED`.
- Else `utf8.sanitize` into a temp (arena or gpa+free after `newString`), `ctx.newString`, free the sanitized copy if `newString` copied.

`newString` copies. Do not return a slice into the env map; the map can change in tests.

Do not use `pending.rejected`. That API is for promises.

## 5. Host install

`src/js/host.zig`:

```zig
const http_module = @import("native/http.zig");
const env_module = @import("native/env.zig");
```

In `createWith`, next to `exec_module.install(self)`:

```zig
http_module.install(self);
env_module.install(self);
```

Add `"http"` to `default_baked` names. Do not add `"env"` there. `env` is native-only.

## 6. Tests

Read `src/js/tests/README.md` first.

- Zig owns the host, the reactor, and `pumpUntilIdle`.
- JS asserts behavior with `check` or `globalThis.result`.
- A JS module must not `await` native I/O before the Zig owner can pump. The established pattern is: eval the module (it starts an async IIFE or a dangling promise), then `support.pumpUntilIdle(host)`, then read `globalThis.result`.
- Argument refusals settle immediately; still pump (jobs run `.catch`).
- Network tests need `zio.Runtime.init(..., .{ .executors = .exact(1) })` and `Host.createTest(allocator, rt.io(), cwd)`.
- No internet. No HTTPS. Loopback HTTP only.

### Env

Zig test: `Host.create` (no reactor).

Present-key: do not mutate the global `Host.test_env` if you can avoid it (parallel tests). Use `Host.createWith`:

```zig
var env_map: std.process.Environ.Map = .init(testing.allocator);
defer env_map.deinit();
try env_map.put("YUKE_TEST_ENV", "secret");
const host = Host.createWith(testing.allocator, testing.io, .{
    .cwd = "",
    .execution = execution.testContext(&env_map),
});
```

JS:

- `env.get("YUKE_TEST_ENV") === "secret"`
- `env.get("YUKE_TEST_ENV_MISSING") === undefined`
- `typeof env.get` is `function`
- Bad name throws; `host.ops.live.items.len === 0`

### Fetch refusals

No server. `Host.create` is enough if parse rejects before `startTask`. If parse runs on the owner and returns `rejected()`, there is no live op.

JS (`http-refuse.test.js`) covers every argument row in the error table. Compare exact `e.message` strings, like `exec.test.js`.

Include forged signals (`null`, `false`, `{}`, `{ aborted: false }`) like `exec-signal.test.js`. Count refusals. Expect zero live ops.

### Fetch loopback

Copy the listen/spawn pattern from `src/net/http.zig` tests (`FormServer` / `exchangeForm`):

1. `zio.Runtime.init`.
2. `zio.net.IpAddress.parseIp4("127.0.0.1", 0).listen`.
3. Spawn a server task that `accept`s once, `std.http.Server.receiveHead`, `request.respond(...)`.
4. Create the host on `rt.io()`.
5. Build a NUL-terminated URL `http://127.0.0.1:{port}/` and `host.eval` a script that sets `globalThis.base`.
6. `support.eval` the JS file.
7. `support.pumpUntilIdle`.
8. Join the server task. Assert `server.err == null`.

Server modes (one Zig test each):

| Mode | Server | JS expect |
|---|---|---|
| `reply` | 200, body `{"ok":true}`, header `X-Test: yes` | `res.ok`, `res.status === 200`, `(await res.json()).ok === true`, `(await res.text())` is that JSON, `res.headers.get("x-test") === "yes"` |
| `echo` | 200, body = request body, record `Content-Type` and a custom request header | POST `{"q":"hi"}` with `Content-Type: application/json` and `X-Token: abc`; body and headers round-trip |
| `missing` | 404, body `nope` | `res.ok === false`, `res.status === 404`, `await res.text() === "nope"` |
| `redirect` | 302, `Location: http://127.0.0.1/elsewhere` | reject, message `the request was redirected` |
| `oversize` | 200, body longer than 256 KiB | reject, message `the response exceeds the size limit` |
| `stall` | read request, then `zio.sleep(.fromMilliseconds(400))` and do not respond | `timeoutMs: 200`, reject `the request timed out`, wall time bound like exec deadline (`< 20s`) |
| `head` | 200, no body | HEAD, `res.ok`, text empty or short |

Custom request header: JS sends `X-Token`. Server iterates request headers (see `FormServer` `iterateHeaders`) and records it. Zig asserts the recorded value after join, or JS reads an echo header.

GET with a query string in the URL (`?q=hi`) must work. The native layer does not parse query; it is part of the URL.

### Fetch signal

Copy `exec-signal.test.js` / the Zig test `exec rejects forged and retained signals and aborts before process creation`.

Replace `exec(...)` with `fetch(globalThis.base, { signal, timeoutMs: 30_000 })` against a stalling server so cancel happens during I/O.

Expect:

- Forged signals reject and do not start ops.
- Two in-flight fetches abort when the tool call finishes (`prelaunch === 2`).
- Retained signal is aborted.
- A late `fetch` with the retained signal rejects without sending (or rejects immediately). Use a server that 200s if a request arrives after abort, and assert it did not.

If a stalling server makes join awkward, bound the server sleep and still assert the fetch promise rejected with `the request was canceled`.

## 7. Style

- Zig names: `TitleCase` types, `camelCase` functions, `snake_case` fields, `SCREAMING_SNAKE` or `snake_case` constants per std.
- Comments: one line only. STE100. Ownership, invariants, protocol. No narration.
- Assert on internal state (phase, op.result == null, header bounds). Never assert on URL/header bytes from JS; those reject.
- `gpa.dupe` failures: `catch unreachable` matches exec/fs.
- `zig fmt` every edited Zig file.
- `zig build test-js` must stay green. Filter new tests while iterating, then run the JS suite.
- `mise run check-ts` after JS/d.ts changes.
- Do not add a Claude co-author trailer. Do not commit unless asked.

## 8. Implementation order

1. `pending.Result.http` + settle/free. Run existing `zig build test-js` once so the new variant does not break `exec`/`fs`.
2. `native/http.zig` parse + `jsFetch` refusals (worker can be a stub that fails). Refusal tests green.
3. Worker + loopback GET/POST/404/HEAD/headers.
4. Redirect, oversize, timeout.
5. Signal cancel.
6. `http.js` + types. Point JS tests at `yuke:http` (not `-native`) so `res.ok` / `res.json()` / `headers.get` are covered.
7. `native/env.zig` + types + tests.
8. `zig fmt`, `zig build test-js`, `mise run check-ts`.

## 9. Out of scope

- `~/.config/yuke/tools/web_search.js`
- Shared client / keep-alive
- `redirect: "follow"`
- WHATWG Request, FormData, Blob, streams, `clone`, `arrayBuffer`, `bodyUsed`
- `AbortController` / timers
- `query` init field
- Argv `exec`
- HTTPS unit tests
- Allocation benchmarks
- Protocol / schema changes

## 10. Copy-from index

| Need | File |
|---|---|
| Native function module | `src/js/native/exec.zig` `install` / `jsExec` / `Request.parse` |
| Native object module | `src/js/native/fs.zig` `installObject` |
| Task + cancel join | `src/js/native/exec.zig` `execTask` / `execWorker` |
| Promise reject messages | `src/js/pending.zig` `rejected` |
| Settle text vs json | `src/js/pending.zig` `call` — add `.http` beside `.text` |
| HTTP POST + no redirect + cap | `src/net/http.zig` `sendGrant` |
| Header slice invalidation | `lib/ai/transport/http.zig` after `receiveHead` |
| RFC 9110 header checks | `lib/ai/instance.zig` `validHeaderName` / `validHeaderValue` (copy, do not import) |
| UTF-8 for JS strings | `src/utf8.zig` `sanitize` |
| Loopback server test | `src/net/http.zig` `FormServer` / `exchangeForm` |
| JS refusal table | `src/js/tests/native_tools/exec.test.js` |
| JS deadline | `src/js/tests/native_tools/deadline.test.js` |
| Signal contract | `src/js/tests/native_tools/exec-signal.test.js` + Zig test in `native_tools_test.zig` |
| Baked module list | `src/js/host.zig` `default_baked` |
| Native d.ts | `src/js/app/types/exec.d.ts` |
| Test README | `src/js/tests/README.md` |
| `std.http.Client.request` | Zig 0.16 `lib/std/http/Client.zig` `RequestOptions`, `Headers`, `redirect_behavior = .not_allowed` |
| Methods | Zig 0.16 `lib/std/http.zig` `Method` |

## 11. Motivating caller (do not implement)

After this work, `web_search.js` can become:

```js
import { fetch } from "yuke:http";
import { env } from "yuke:env";
import { fs } from "yuke:fs";

const key = env.get("BRAVE_API_KEY") ?? parseEnvFile(await fs.readFile("~/.config/yuke/.env"));
const res = await fetch(
  `${BRAVE_URL}?q=${encodeURIComponent(query)}&count=${maxResults}`,
  {
    headers: { "X-Subscription-Token": key, Accept: "application/json" },
    timeoutMs: 15_000,
    signal,
  },
);
if (!res.ok) return null;
return parseResults(await res.text(), "web", "description");
```

That rewrite is a later change to the user's config, not this repository.
