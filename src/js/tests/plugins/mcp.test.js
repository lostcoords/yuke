import { fs } from "yuke:fs";
import { interaction, plugins } from "yuke:ext";
import { mcp, toolName } from "yuke:mcp";
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
    tools/call) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%s says %s%s"}]}}\n' "$id" "$GREETING" "$text" "$pinged" ;;
`, String.raw`echo 'server log line'; echo 'to stderr' >&2; pinged=""
`);
// A modern server: two tool pages, every result kind, a slow call, and a list change after `change`.
const MODERN = server(String.raw`    server/discover) case "$line" in
      *'"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{"listChanged":true}}}}\n' "$id" ;;
      *) exit 9 ;;
    esac ;;
    tools/list) case "$line" in
      *'"cursor":"p2"'*) if [ "$changed" = 1 ]; then printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"added","inputSchema":{"type":"object","properties":{}}}]}}\n' "$id"; else printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"a.tool","title":"A tool"},{"name":"a_tool","title":"Another"}]}}\n' "$id"; fi ;;
      *) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[{"name":"echo","description":"Echo the text.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}}}],"nextCursor":"p2"}}\n' "$id" ;;
    esac ;;
    tools/call) case "$text" in
      fail) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"no such thing"}],"isError":true}}\n' "$id" ;;
      media) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"image","data":"AAAA","mimeType":"image/png"},{"type":"resource_link","uri":"file:///x","name":"x"},{"type":"resource","resource":{"uri":"file:///y","text":"why"}}]}}\n' "$id" ;;
      structured) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[],"structuredContent":{"n":1}}}\n' "$id" ;;
      input) printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"input_required","inputRequests":{},"requestState":"s"}}\n' "$id" ;;
      change) changed=1; printf '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}\n'; printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"changed"}]}}\n' "$id" ;;
      big) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"' "$id"; head -c 120000 /dev/zero | tr '\0' x; printf '"}]}}\n' ;;
      slow) sleep 2; printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"late"}]}}\n' "$id" ;;
      *) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"modern: %s"}]}}\n' "$id" "$text" ;;
    esac ;;
`, String.raw`changed=0
`);
// A legacy server that exits inside its first tool call.
const DIES = server(String.raw`    server/discover) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    initialize) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2024-11-05","capabilities":{}}}\n' "$id" ;;
    tools/list) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo"}]}}\n' "$id" ;;
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
      silent: sh("exec cat >/dev/null"),
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

// A workspace `.mcp.json` server waits for trust. The answerer records the question and answers `mcpAnswer`.
if (mcpCase === "trust") {
  globalThis.asked = [];
  interaction.install({
    interactive: true,
    notify() {},
    open(request, _context, _options, resolve) { globalThis.asked.push(request.title); resolve(globalThis.mcpAnswer); return () => {}; },
  });
  globalThis.mcpStart = async () => {
    await fs.writeFile(".mcp.json", JSON.stringify({ mcpServers: { ws: { ...sh(LEGACY), env: { ...env, GREETING: "hello" } } } }));
    globalThis.mcpPlugin = mcp({ startupMs: 3000 });
    await plugins.use(globalThis.mcpPlugin).ready;
  };
}
