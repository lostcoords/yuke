import { lines } from "yuke:spawn";
import { fs } from "yuke:fs";
import { interaction, plugins } from "yuke:ext";
import { mcp, toolName, decodeMessage, toolResult } from "yuke:mcp";
import { check, equal } from "yuke:test";

// The shell servers answer one JSON-RPC line per request. `sed` reads the id, the method, and the text argument.
const READ = String.raw`while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
  text=$(printf '%s' "$line" | sed -n 's/.*"text":"\([^"]*\)".*/\1/p')
  case "$line" in *'"id":777,"result":{}'*) pinged=" pinged" ;; esac
  case "$method" in
`;
const END = String.raw`  esac
done`;
/** @param {string} cases @param {string} [setup] */
const server = (cases, setup = "") => setup + READ + cases + END;
// A legacy server: it logs to stdout once, refuses `server/discover`, needs `initialize` first, then pings the client.
const LEGACY = server(String.raw`    server/discover) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"legacy","version":"1"}}}\r\n' "$id" ;;
    notifications/initialized) printf '{"jsonrpc":"2.0","id":777,"method":"ping"}\n' ;;
    tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echo the text.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}]}}\n' "$id" ;;
    tools/call) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"%s says %s%s"}]}}\n' "$id" "$GREETING" "$text" "$pinged" ;;
`, String.raw`echo 'server log line'; echo 'to stderr' >&2; pinged=""
`);
// A modern server: two tool pages, every result kind, a slow call, and a list change after `change`.
const MODERN = server(String.raw`    server/discover) case "$line" in
      *'"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true}}}}\n' "$id" ;;
      *) exit 9 ;;
    esac ;;
    tools/list) case "$line" in
      *'"cursor":"p2"'*) if [ "$changed" = 2 ]; then printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"bad"}]}}\n' "$id"; elif [ "$changed" = 1 ]; then printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"added","inputSchema":{"type":"object","properties":{}}}]}}\n' "$id"; else printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"a.tool","title":"A tool","inputSchema":{"type":"object"}},{"name":"a_tool","title":"Another","inputSchema":{"type":"object"}}]}}\n' "$id"; fi ;;
      *) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"echo","description":"Echo the text.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}],"nextCursor":"p2"}}\n' "$id" ;;
    esac ;;
    tools/call) case "$text" in
      fail) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"no such thing"}],"isError":true}}\n' "$id" ;;
      media) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"resource_link","uri":"file:///x","name":"x"},{"type":"resource","resource":{"uri":"file:///y","text":"why"}}]}}\n' "$id" ;;
      structured) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[],"structuredContent":{"n":1}}}\n' "$id" ;;
      input) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"input_required","inputRequests":{},"requestState":"s"}}\n' "$id" ;;
      badchange) changed=2; printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'; printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"changed"}]}}\n' "$id" ;;
      change) changed=1; printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'; printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"changed"}]}}\n' "$id" ;;
      big) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"' "$id"; head -c 120000 /dev/zero | tr '\0' x; printf '"}]}}\n' ;;
      slow) delayed_id=$id ;;
      after-timeout) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"canceled: %s"}]}}\n' "$id" "$canceled" ;;
      *) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"modern: %s"}]}}\n' "$id" "$text" ;;
    esac ;;
    notifications/cancelled) request_id=$(printf '%s' "$line" | sed -n 's/.*"requestId":\([0-9]*\).*/\1/p')
    if [ -n "$delayed_id" ] && [ "$request_id" = "$delayed_id" ]; then
      canceled=yes
      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"late"}]}}\n' "$delayed_id"
      delayed_id=""
    fi ;;
`, String.raw`changed=0; delayed_id=""; canceled=no
`);
// A legacy server that exits inside its first tool call.
const DIES = server(String.raw`    server/discover) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"dies","version":"1"}}}\n' "$id" ;;
    tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
    tools/call) echo 'boom' >&2; exit 3 ;;
`);
// A modern-only server that speaks another version, and a legacy server that answers a version this client never learned.
const MODERN_ONLY = server(String.raw`    server/discover) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2027-01-01"]}}}\n' "$id" ;;
`);
const OLD_VERSION = server(String.raw`    server/discover) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"1999-01-01","capabilities":{}}}\n' "$id" ;;
`);

const env = { PATH: "/usr/bin:/bin" };
/** @param {string} script @returns {import("yuke:mcp").ServerConfig} */
const sh = (script) => ({ command: "/bin/sh", args: ["-c", script], env });

/** @returns {Record<string, string>} */
globalThis.mcpStates = () => Object.fromEntries(globalThis.mcpPlugin.rows());
globalThis.mcpSettled = () => Object.values(globalThis.mcpStates()).every((/** @type {string} */ row) => !row.startsWith("pending") && !row.startsWith("connecting"));

if (mcpCase === "servers") {
  equal(toolName("srv", "a.b"), "mcp_srv_a_b");
  const long = toolName("server", "x".repeat(80));
  equal(long.length, 64);
  equal(long, toolName("server", "x".repeat(80)));
  check("a different long name hashes differently", long !== toolName("server", "x".repeat(79) + "y"));

  globalThis.mcpPlugin = mcp({
    startupMs: 3000,
    callMs: 500,
    servers: {
      legacy: { ...sh(LEGACY), env: { ...env, GREETING: "${MCP_TEST_GREETING:-hi}" } },
      modern: sh(MODERN),
      dies: sh(DIES),
      modernonly: sh(MODERN_ONLY),
      oldver: sh(OLD_VERSION),
      missing: { command: "${MCP_TEST_MISSING}" },
      badargs: { command: "/bin/sh", args: "-c" },
      remote: { url: "https://example.com/mcp" },
      off: { command: "/bin/sh", enabled: false },
    },
  });
  globalThis.mcpReady = false;
  plugins.use(globalThis.mcpPlugin).ready.then(() => { globalThis.mcpReady = true; });
}

if (mcpCase === "timeout") {
  globalThis.mcpPlugin = mcp({ startupMs: 3000, callMs: 100, servers: { modern: sh(MODERN) } });
  globalThis.mcpReady = false;
  plugins.use(globalThis.mcpPlugin).ready.then(() => { globalThis.mcpReady = true; });
}

if (mcpCase === "silent") {
  globalThis.mcpPlugin = mcp({ startupMs: 100, servers: { silent: sh("exec cat >/dev/null") } });
  globalThis.mcpReady = false;
  plugins.use(globalThis.mcpPlugin).ready.then(() => { globalThis.mcpReady = true; });
}

// A workspace `.mcp.json` server waits for trust. The answerer records the question and answers `mcpAnswer`.
if (mcpCase === "trust") {
  globalThis.asked = [];
  interaction.install({
    interactive: true,
    notify() {},
    open(request, _context, _options, resolve) { globalThis.asked.push(request.title); resolve(globalThis.mcpAnswer); return () => {}; },
  });
  globalThis.mcpStart = async (greeting = "hello") => {
    await fs.writeFile(".mcp.json", JSON.stringify({ mcpServers: { ws: { ...sh(LEGACY), enabled: globalThis.mcpEnabled ?? true, timeout: globalThis.mcpTimeout ?? 500, env: globalThis.mcpReorder ? { GREETING: greeting, ...env } : { ...env, GREETING: greeting } } } }));
    globalThis.mcpPlugin = mcp({ startupMs: 3000 });
    await plugins.use(globalThis.mcpPlugin).ready;
  };
}


if (mcpCase === "validation") {
  const rejects = (label, fn) => {
    let failed = false;
    try { fn(); } catch { failed = true; }
    check(label, failed);
  };
  for (const value of [null, [], {}, { jsonrpc: "1.0", id: 1, result: {} },
    { jsonrpc: "2.0", id: 1, result: {}, error: { code: 0, message: "no" } },
    { jsonrpc: "2.0", result: {} }, { jsonrpc: "2.0", id: true, result: {} },
    { jsonrpc: "2.0", id: 1.5, result: {} }, { jsonrpc: "2.0", id: 1, result: [] },
    { jsonrpc: "2.0", id: 1, error: { code: "bad", message: "no" } },
    { jsonrpc: "2.0", id: 1, error: { code: 1 } },
    { jsonrpc: "2.0", method: "ping", id: null },
    { jsonrpc: "2.0", method: "ping", params: [] },
    { jsonrpc: "2.0", method: "ping", result: {} },
  ]) rejects("bad envelope " + JSON.stringify(value), () => decodeMessage(JSON.stringify(value)));
  rejects("bad JSON", () => decodeMessage("{"));
  equal(decodeMessage('  {"jsonrpc":"2.0","id":1,"result":{},"extension":true}').id, 1);
  equal(decodeMessage('{"jsonrpc":"2.0","method":"ping","id":"peer"}').id, "peer");
  equal(decodeMessage('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse"}}').id, null);
  for (const result of [null, {}, { content: null }, { content: [], isError: "false" },
    { content: [], structuredContent: [] }, { content: [], resultType: "unknown" },
    ...[{}, null, { type: "text", text: 3 }, { type: "image", data: "x" },
      { type: "audio", mimeType: "audio/wav" }, { type: "resource_link", uri: "x" },
      { type: "resource", resource: { uri: "x" } }, { type: "future" },
    ].map((block) => ({ content: [block] })),
  ]) rejects("bad result " + JSON.stringify(result), () => toolResult(result));
  rejects("modern tag required", () => toolResult({ content: [] }, true));
  equal(toolResult({ content: [] }), "");
  equal(toolResult({ resultType: "complete", content: [{ type: "text", text: "ok", extension: 1 }] }, true), "ok");
  equal(toolResult({ content: [{ type: "text", text: "x".repeat(99999) }, { type: "text", text: "yy" }] }), "x".repeat(99999) + "\n\n[truncated 2 characters]");
  let overflow = 0;
  const got = [];
  const feed = lines((line) => got.push(line), () => overflow++);
  feed("x".repeat(1024 * 1024 + 1) + "\nok\n");
  feed("x".repeat(1024 * 1024 + 1));
  feed("tail\nlast\n");
  equal(overflow, 2);
  equal(got.join(","), "ok,last");
}

if (mcpCase === "protocol") {
  const discovery = String.raw`    server/discover) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}\n' "$id" ;;
`;
  const list = (result) => sh(server(discovery + `    tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":${JSON.stringify({ resultType: "complete", ...result })}}\\n' "$id" ;;
`));
  globalThis.mcpPlugin = mcp({ startupMs: 3000, servers: {
    version: sh(server(discovery.replace("2026-07-28", "2099-01-01"))),
    noTools: sh(server(discovery.replace('"tools":{}', ''))),
    capabilities: sh(server(discovery.replace('"tools":{}', '"tools":true'))),
    envelope: sh(server(discovery.replace('"jsonrpc":"2.0"', '"jsonrpc":"1.0"'))),
    duplicate: list({ tools: [{ name: "same", inputSchema: { type: "object" } }, { name: "same", inputSchema: { type: "object" } }] }),
    schema: list({ tools: [{ name: "missing" }] }),
    cursor: list({ tools: [], nextCursor: "again" }),
  } });
  globalThis.mcpReady = false;
  plugins.use(globalThis.mcpPlugin).ready.then(() => { globalThis.mcpReady = true; });
}
