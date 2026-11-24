/**
 * The bundled plugin `mcp` adds `/mcp`. It lists the MCP servers of the session in the active pane with their states. A
 * server that needs a login opens a dialog with the page of the login, and a field for the address of the redirect for
 * a browser that cannot reach yuke. `/mcp logout <server>` removes the stored login of a server.
 */

import { openBrowser } from "yuke:internal/browser";
import { mcp as logins, type McpLoginInProgress, type McpLogins } from "yuke:internal/sessions";
import type { PluginContext } from "yuke:plugins";
import type { LoginOutcome, McpServer, McpServerState, SessionId } from "yuke:protocol";
import type { Canvas, Tui, View } from "yuke:tui";

/** The text of a server state in a list. */
function stateText(state: McpServerState): string {
  switch (state.kind) {
    case "connected":
      return `connected · ${state.tools} ${state.tools === 1 ? "tool" : "tools"}`;
    case "connecting":
      return "connecting";
    case "needsLogin":
      return "needs login";
    case "failed":
      // An error can hold the last lines of the program, and the list shows one line.
      return `failed · ${state.error.split("\n")[0] ?? ""}`;
    case "disabled":
      return "disabled";
    case "untrusted":
      return "not trusted";
  }
}

/** The MCP servers of the session `id` now. */
async function serversOf(ctx: PluginContext, id: SessionId): Promise<readonly McpServer[]> {
  const stop = new AbortController();
  try {
    const handle = await ctx.get("sessions").open(id, { tail: 0, signal: stop.signal, onEvent: () => {} });
    return handle.mcpServers();
  } finally {
    stop.abort();
  }
}

/** Run the login of `server` in a dialog. The close of the dialog cancels the login. */
async function openLoginDialog(
  ctx: PluginContext,
  tui: Tui,
  sessionId: SessionId,
  server: string,
  mcp: McpLogins,
): Promise<void> {
  let login: McpLoginInProgress | undefined;
  const running = (): boolean => login !== undefined;
  const body: View = {
    draw: (canvas: Canvas) => {
      if (login === undefined) {
        canvas.text(0, 0, "The login starts…", "chat.meta");
        return;
      }
      // The URL is long, and a part of it looks like a link that the user can open. So the dialog shows only the host.
      canvas.text(0, 0, `Press o to open the login page of ${new URL(login.url).host} in the browser,`);
      canvas.text(0, 1, "or u to copy its URL.");
    },
  };
  const dialog = tui.dialog({
    title: `Log in · ${server}`,
    body,
    rows: 5,
    keys: [
      {
        key: "o",
        label: "open",
        when: running,
        run: () => {
          if (login === undefined) return;
          void openBrowser(login.url, ctx.dataDir).then((opened) => {
            if (!opened) ctx.notify("error", "The browser did not open: copy the URL with u");
          });
        },
      },
      {
        key: "u",
        label: "copy URL",
        when: running,
        run: () => {
          if (login === undefined) return;
          tui.clipboard.writeText(login.url);
          ctx.notify("info", "URL copied");
        },
      },
      {
        key: "p",
        label: "paste address",
        when: running,
        // An address that is not the redirect of the login keeps the field open with the reason.
        run: () => {
          void tui.prompt({
            title: "Address of the redirect",
            placeholder: "http://127.0.0.1:…/callback?code=…",
            signal: dialog.signal,
            onSubmit: (text) => {
              const address = text.trim();
              if (address === "") throw new Error("type the address first");
              login?.complete(address);
            },
          });
        },
      },
    ],
  });
  let outcome: LoginOutcome;
  try {
    login = await mcp.login(sessionId, server, { signal: dialog.signal });
    tui.requestFrame();
    outcome = await login.waitForEnd();
  } catch (error) {
    dialog.close();
    ctx.notify("error", `The login failed: ${String(error)}`);
    return;
  }
  const closedByUser = dialog.signal.aborted;
  if (!closedByUser) dialog.close();
  if (outcome.kind === "succeeded") ctx.notify("info", `Logged in · ${server}`);
  else if (outcome.kind === "failed") ctx.notify("error", `The login failed: ${outcome.error}`);
  else if (!closedByUser) ctx.notify("info", "Login cancelled");
}

/** Act on the choice of `server`: a login for a server that needs one, else a notice. */
function choose(ctx: PluginContext, tui: Tui, sessionId: SessionId, server: McpServer, mcp: McpLogins): void {
  if (server.state.kind === "needsLogin") void openLoginDialog(ctx, tui, sessionId, server.name, mcp);
  else if (server.state.kind === "failed") ctx.notify("error", `${server.name} failed: ${server.state.error}`);
  else ctx.notify("info", `${server.name} needs no login`);
}

/** Run `/mcp`. `args` is the text after the command: empty, a server name, or `logout <server>`. */
async function run(ctx: PluginContext, tui: Tui, args: unknown, mcp: McpLogins): Promise<void> {
  const pane = tui.panes.activePane?.view;
  const sessionId = pane === undefined ? undefined : ctx.get("chat").sessionIdOf(pane);
  if (sessionId === undefined) {
    ctx.notify("info", "No session is shown in this pane");
    return;
  }
  const words = typeof args === "string" ? args.trim() : "";
  const logout = /^logout(?:\s+(.*))?$/.exec(words);
  if (logout !== null) {
    const name = logout[1];
    if (name === undefined) {
      ctx.notify("error", "Name the server: /mcp logout <server>");
      return;
    }
    try {
      await mcp.logout(sessionId, name);
      ctx.notify("info", `Logged out · ${name}`);
    } catch (error) {
      ctx.notify("error", `The logout failed: ${String(error)}`);
    }
    return;
  }
  const servers = await serversOf(ctx, sessionId);
  if (servers.length === 0) {
    ctx.notify("info", "The session has no MCP servers");
    return;
  }
  if (words === "") {
    const server = await tui.select({
      items: servers,
      title: "MCP servers",
      label: (item) => `${item.name} · ${item.source}`,
      detail: (item) => stateText(item.state),
    });
    if (server !== undefined) choose(ctx, tui, sessionId, server, mcp);
    return;
  }
  const server = servers.find((item) => item.name === words);
  if (server === undefined) ctx.notify("error", `The session has no MCP server ${words}`);
  else choose(ctx, tui, sessionId, server, mcp);
}

/** A test gives fake logins as `mcp`. */
export function apply(ctx: PluginContext, mcp: McpLogins = logins): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  tui.commands.add({
    name: "mcp",
    slash: "mcp",
    argumentHint: "[server | logout <server>]",
    description: "List the MCP servers, log in to one, or log out",
    run: (args) => run(ctx, tui, args, mcp),
  });
  return undefined;
}
