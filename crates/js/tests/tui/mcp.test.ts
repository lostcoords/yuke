// The bundled plugin `mcp`: the list of the MCP servers of the shown session, the login dialog, and the logout.

import { apply } from "yuke:internal/bundled/mcp";
import type { McpLogins } from "yuke:internal/sessions";
import type { LoginOutcome, McpServer } from "yuke:protocol";
import { assertEquals, createFrame, type FrameTest, test, waitForSettled } from "yuke:test";
import { fakeSessions, loadChat, replies } from "./chat.ts";
import { fakeContext } from "./context.ts";

const SERVERS: McpServer[] = [
  { name: "docs", source: "user", state: { kind: "connected", tools: 3 } },
  { name: "linear", source: "user", state: { kind: "needsLogin" } },
  { name: "git", source: "project", state: { kind: "connecting" } },
  { name: "broken", source: "user", state: { kind: "failed", error: "the server stopped\nthe last line" } },
  { name: "off", source: "user", state: { kind: "disabled" } },
  { name: "proj", source: "project", state: { kind: "untrusted" } },
];

/** The page of each fake login: a real page is longer than the dialog is wide. */
const URL = `https://auth.example.com/authorize?response_type=code&client_id=https%3A%2F%2Fyuke.sh%2Foauth%2Fclient.json&redirect_uri=http%3A%2F%2F127.0.0.1%3A53682%2Fcallback&code_challenge=${"x".repeat(43)}&code_challenge_method=S256&state=${"y".repeat(22)}&resource=https%3A%2F%2Fmcp.example.com%2Fmcp`;

/** Load the plugin in `frame` on a chat that shows the session `s1` with `servers`. A test ends a login with `end`. */
async function load(frame: FrameTest, servers: readonly McpServer[] = SERVERS) {
  const calls: string[] = [];
  const signals: AbortSignal[] = [];
  let refusal: string | undefined;
  let startFailure: string | undefined;
  let logoutFailure: string | undefined;
  let end: (outcome: LoginOutcome) => void = () => {};
  const mcp: McpLogins = {
    login: async (sessionId, server, options) => {
      calls.push(`login ${sessionId} ${server}`);
      if (startFailure !== undefined) throw new Error(startFailure);
      const signal = options?.signal;
      if (signal === undefined) throw new Error("the plugin starts a login without a signal");
      signals.push(signal);
      const ended = new Promise<LoginOutcome>((resolve) => {
        end = resolve;
        signal.addEventListener("abort", () => resolve({ kind: "cancelled" }));
      });
      return {
        url: URL,
        complete: (address) => {
          calls.push(`complete ${address}`);
          if (refusal !== undefined) throw new Error(refusal);
        },
        waitForEnd: () => ended,
      };
    },
    logout: async (sessionId, server) => {
      calls.push(`logout ${sessionId} ${server}`);
      if (logoutFailure !== undefined) throw new Error(logoutFailure);
    },
  };
  const sessions = fakeSessions(replies(2));
  sessions.state.mcpServers = servers;
  const chat = await loadChat(frame, sessions);
  const surface = frame.surface("mcp");
  const { ctx, notices } = fakeContext({ name: "mcp", services: { tui: surface.tui, sessions, chat: chat.chat } });
  apply(ctx, mcp);
  frame.start();
  await waitForSettled();
  return {
    notices,
    calls,
    signals,
    refuseWith: (text: string | undefined) => {
      refusal = text;
    },
    failStartWith: (text: string) => {
      startFailure = text;
    },
    failLogoutWith: (text: string) => {
      logoutFailure = text;
    },
    end: (outcome: LoginOutcome) => end(outcome),
    run: async (args?: string) => {
      surface.tui.commands.run("mcp:mcp", args);
      await waitForSettled();
      frame.draw();
      return frame.rows();
    },
  };
}

/** The row of `frame` that holds `text`. */
function rowWith(frame: FrameTest, text: string): string | undefined {
  return frame.rows().find((row) => row.includes(text));
}

/** A frame that shows the session `s1`. */
function frameOf() {
  return createFrame({ width: 80, height: 16 }, undefined, { folder: "/w", sessionId: "s1" });
}

test("/mcp lists each server of the session with its source and its state", async () => {
  using frame = frameOf();
  const mcp = await load(frame);

  const shown = (await mcp.run()).join("\n");

  for (const [name, text] of [
    ["docs · user", "connected · 3 tools"],
    ["linear · user", "needs login"],
    ["git · project", "connecting"],
    ["broken · user", "failed · the server stopped"],
    ["off · user", "disabled"],
    ["proj · project", "not trusted"],
  ] as const) {
    const row = rowWith(frame, name);
    assertEquals(row?.includes(text), true, `${name}: ${shown}`);
  }
  // The list shows one line of an error.
  assertEquals(shown.includes("the last line"), false);
  assertEquals(mcp.calls, []);
});

test("a server that needs a login opens the dialog with its page, and its keys copy and open it", async () => {
  using frame = frameOf();
  const mcp = await load(frame);
  await mcp.run();

  frame.key("l i n enter");
  await waitForSettled();
  frame.draw();
  const shown = frame.rows().join("\n");
  frame.key("u");

  assertEquals(mcp.calls, ["login s1 linear"]);
  assertEquals(shown.includes("Log in · linear"), true);
  // The dialog names the host and shows nothing that looks like a link. The copy key gives the whole URL.
  assertEquals(shown.includes("Press o to open the login page of auth.example.com in the browser,"), true);
  assertEquals(shown.includes("or u to copy its URL."), true);
  assertEquals(shown.includes("https://"), false);
  assertEquals(shown.includes("o: open"), true);
  assertEquals(shown.includes("p: paste address"), true);
  assertEquals(frame.copies, [URL]);
  assertEquals(mcp.notices, ["info URL copied"]);
  frame.key("esc");
  await waitForSettled();
});

test("a pasted address completes the login, and the end of the login closes the dialog with its notice", async () => {
  using frame = frameOf();
  const mcp = await load(frame);
  await mcp.run("linear");

  frame.key("p");
  await waitForSettled();
  frame.paste("  http://127.0.0.1:5000/callback?code=c&state=s \n");
  frame.key("enter");
  await waitForSettled();
  mcp.end({ kind: "succeeded" });
  await waitForSettled();
  frame.draw();

  assertEquals(mcp.calls, ["login s1 linear", "complete http://127.0.0.1:5000/callback?code=c&state=s"]);
  assertEquals(mcp.notices, ["info Logged in · linear"]);
  assertEquals(rowWith(frame, "Log in · linear"), undefined);
  assertEquals(rowWith(frame, "Address of the redirect"), undefined);
});

test("an address that is not the redirect keeps the field and the dialog open with the reason", async () => {
  using frame = frameOf();
  const mcp = await load(frame);
  mcp.refuseWith("the state of the redirect is not the state of this login");
  await mcp.run("linear");

  frame.key("p");
  await waitForSettled();
  frame.key("enter");
  await waitForSettled();
  const afterEmpty = [...mcp.calls];
  frame.paste("http://127.0.0.1:5000/callback?code=c&state=wrong");
  frame.key("enter");
  await waitForSettled();
  frame.draw();

  assertEquals(afterEmpty, ["login s1 linear"]);
  assertEquals(mcp.calls.at(-1), "complete http://127.0.0.1:5000/callback?code=c&state=wrong");
  assertEquals(rowWith(frame, "the state of the redirect is not the state of this login") !== undefined, true);
  assertEquals(rowWith(frame, "Address of the redirect") !== undefined, true);
  assertEquals(rowWith(frame, "Log in · linear") !== undefined, true);
  assertEquals(mcp.notices, []);
  frame.key("esc");
  frame.key("esc");
  await waitForSettled();
});

test("each end of a login closes the dialog with its notice, and esc cancels the login with no notice", async () => {
  for (const [outcome, notice] of [
    [{ kind: "succeeded" }, "info Logged in · linear"],
    [{ kind: "failed", error: "denied" }, "error The login failed: denied"],
    [{ kind: "cancelled" }, "info Login cancelled"],
  ] as const) {
    using frame = frameOf();
    const mcp = await load(frame);
    await mcp.run("linear");

    mcp.end(outcome);
    await waitForSettled();
    frame.draw();

    assertEquals(mcp.notices, [notice]);
    assertEquals(rowWith(frame, "Log in · linear"), undefined);
  }

  using frame = frameOf();
  const mcp = await load(frame);
  await mcp.run("linear");
  frame.key("esc");
  await waitForSettled();

  assertEquals(mcp.signals[0]?.aborted, true);
  assertEquals(mcp.notices, []);
});

test("a login that does not start closes the dialog with a notice", async () => {
  using frame = frameOf();
  const mcp = await load(frame);
  mcp.failStartWith("the server needs oauth.clientId");

  await mcp.run("linear");

  assertEquals(mcp.notices, ["error The login failed: Error: the server needs oauth.clientId"]);
  assertEquals(rowWith(frame, "Log in · linear"), undefined);
});

test("/mcp logout removes the login of a server and gives a notice, also for a failure", async () => {
  using frame = frameOf();
  const mcp = await load(frame);

  await mcp.run("logout linear");
  await mcp.run("logout");
  mcp.failLogoutWith("the session has no MCP server nobody");
  await mcp.run("logout nobody");

  assertEquals(mcp.calls, ["logout s1 linear", "logout s1 nobody"]);
  assertEquals(mcp.notices, [
    "info Logged out · linear",
    "error Name the server: /mcp logout <server>",
    "error The logout failed: Error: the session has no MCP server nobody",
  ]);
});

test("a server that needs no login gives a notice, a failed one shows its whole error, and a bad name gives an error", async () => {
  using frame = frameOf();
  const mcp = await load(frame);

  await mcp.run("docs");
  await mcp.run("broken");
  await mcp.run("nobody");

  assertEquals(mcp.calls, []);
  assertEquals(mcp.notices, [
    "info docs needs no login",
    "error broken failed: the server stopped\nthe last line",
    "error The session has no MCP server nobody",
  ]);
});

test("/mcp gives a notice for a session without servers and for a chat without a session", async () => {
  using frame = frameOf();
  const none = await load(frame, []);
  await none.run();
  assertEquals(none.notices, ["info The session has no MCP servers"]);

  using bare = createFrame({ width: 80, height: 16 }, undefined, { folder: "/w" });
  const mcp = await load(bare);
  await mcp.run();
  assertEquals(mcp.notices, ["info No session is shown"]);
});
