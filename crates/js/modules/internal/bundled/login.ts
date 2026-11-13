/**
 * The bundled plugin `login` adds `/login` and `/logout`. `/login` replaces the credential of a provider. A masked field
 * takes an API key. A dialog shows the page and the code of a device login. `/logout` removes what yuke stored.
 */

import { type Auth, auth as credentials, type LoginInProgress } from "yuke:internal/sessions";
import type { PluginContext } from "yuke:plugins";
import { Command } from "yuke:process";
import type { LoginOutcome, ProviderInfo, ProviderState } from "yuke:protocol";
import type { Canvas, Tui, View } from "yuke:tui";

/** A notice must not repeat the text after `/login`, because that text can be a key. */
const NO_PROVIDER = "no provider with this id: run /login to see the list";

/** The text of a provider in a list. */
function stateText(state: ProviderState): string {
  if (state.kind !== "ready") return "not connected";
  const credential = state.credential;
  if (credential.kind === "variable") return `connected · $${credential.name}`;
  return credential.kind === "login" ? "connected · login" : "connected · API key";
}

/** Whether `state` holds a credential that yuke stored. */
function isStored(state: ProviderState): boolean {
  return state.kind === "ready" && (state.credential.kind === "storedApiKey" || state.credential.kind === "login");
}

/** Whether the provider of `state` takes a device login, and not an API key. */
function takesLogin(state: ProviderState): boolean {
  return state.kind === "needsLogin" || (state.kind === "ready" && state.credential.kind === "login");
}

/** The providers that take a credential. */
async function providersOf(ctx: PluginContext): Promise<ProviderInfo[]> {
  const catalog = await ctx.get("catalog").list({ all: true });
  return catalog.providers.filter(
    (provider) => provider.state.kind !== "ready" || provider.state.credential.kind !== "none",
  );
}

/** The provider that `args` names, or the choice of the user in a list of `providers` when `args` is absent. */
async function chosen(
  ctx: PluginContext,
  tui: Tui,
  title: string,
  providers: readonly ProviderInfo[],
  args: unknown,
): Promise<ProviderInfo | undefined> {
  if (args === undefined) {
    return tui.select({
      items: providers,
      title,
      label: (provider) => `${provider.name} · ${provider.id}`,
      detail: (provider) => stateText(provider.state),
    });
  }
  const provider = providers.find((candidate) => candidate.id === args);
  if (provider === undefined) ctx.notify("error", NO_PROVIDER);
  return provider;
}

/** Take an API key for `provider` in a masked field. A refused key stays in the field with its error. */
async function openKeyDialog(ctx: PluginContext, auth: Auth, tui: Tui, provider: ProviderInfo): Promise<void> {
  const saved = await tui.input({
    title: `API key · ${provider.name}`,
    placeholder: "API key",
    mask: true,
    onSubmit: async (text) => {
      const key = text.trim();
      if (key === "") throw new Error("type the key first");
      await auth.setApiKey(provider.id, key);
    },
  });
  if (saved !== undefined) ctx.notify("info", `key saved · ${provider.id}`);
}

/** Open `url` in the browser. The module cannot read the platform, and `open` on Linux can be another program. */
async function openBrowser(url: string, cwd: string): Promise<boolean> {
  for (const program of ["xdg-open", "open"]) {
    try {
      const output = await new Command(program, { args: [url], cwd, stdout: "null", stderr: "null" }).output();
      return output.success;
    } catch {
      // This program does not start. The next one can.
    }
  }
  return false;
}

/** Run a device login of `provider` in a dialog. The close of the dialog cancels the login. */
async function openLoginDialog(ctx: PluginContext, auth: Auth, tui: Tui, provider: ProviderInfo): Promise<void> {
  let login: LoginInProgress | undefined;
  const running = (): boolean => login !== undefined;
  const body: View = {
    draw: (canvas: Canvas) => {
      if (login === undefined) {
        canvas.text(0, 0, "The login starts…", "chat.meta");
        return;
      }
      canvas.text(0, 0, "Open this page, and enter the code.");
      canvas.text(0, 1, login.verificationUrl);
      canvas.text(0, 2, `Code: ${login.userCode}`);
    },
  };
  const dialog = tui.dialog({
    title: `Log in · ${provider.name}`,
    body,
    rows: 5,
    keys: [
      {
        key: "o",
        label: "open",
        when: running,
        run: () => {
          if (login === undefined) return;
          void openBrowser(login.verificationUrl, ctx.dataDir).then((opened) => {
            if (!opened) ctx.notify("error", "the browser did not open: copy the URL with u");
          });
        },
      },
      {
        key: "c",
        label: "copy code",
        when: running,
        run: () => {
          if (login === undefined) return;
          tui.clipboard.writeText(login.userCode);
          ctx.notify("info", "code copied");
        },
      },
      {
        key: "u",
        label: "copy URL",
        when: running,
        run: () => {
          if (login === undefined) return;
          tui.clipboard.writeText(login.verificationUrl);
          ctx.notify("info", "URL copied");
        },
      },
    ],
  });
  let outcome: LoginOutcome;
  try {
    login = await auth.login(provider.id, { signal: dialog.signal });
    tui.requestFrame();
    outcome = await login.waitForEnd();
  } catch (error) {
    dialog.close();
    ctx.notify("error", `the login failed: ${String(error)}`);
    return;
  }
  const closedByUser = dialog.signal.aborted;
  if (!closedByUser) dialog.close();
  if (outcome.kind === "succeeded") ctx.notify("info", `logged in · ${provider.id}`);
  else if (outcome.kind === "failed") ctx.notify("error", `the login failed: ${outcome.error}`);
  else if (!closedByUser) ctx.notify("info", "login cancelled");
}

/** Run `/login`. `args` is the text after the command. */
async function runLogin(ctx: PluginContext, auth: Auth, tui: Tui, args: unknown): Promise<void> {
  const provider = await chosen(ctx, tui, "Log in", await providersOf(ctx), args);
  if (provider === undefined) return;
  if (takesLogin(provider.state)) void openLoginDialog(ctx, auth, tui, provider);
  else void openKeyDialog(ctx, auth, tui, provider);
}

/** Run `/logout`. `args` is the text after the command. */
async function runLogout(ctx: PluginContext, auth: Auth, tui: Tui, args: unknown): Promise<void> {
  const providers = await providersOf(ctx);
  const stored = providers.filter((candidate) => isStored(candidate.state));
  if (args === undefined && stored.length === 0) {
    ctx.notify("info", "yuke stores no credential");
    return;
  }
  const provider = await chosen(ctx, tui, "Log out", args === undefined ? stored : providers, args);
  if (provider === undefined) return;
  const state = provider.state;
  if (isStored(state)) {
    await auth.logout(provider.id);
    ctx.notify("info", `logged out · ${provider.id}`);
  } else if (state.kind === "ready" && state.credential.kind === "variable") {
    ctx.notify("info", `${provider.id} has its key in $${state.credential.name}: unset the variable`);
  } else ctx.notify("info", `yuke stores no credential for ${provider.id}`);
}

/** A test gives fake credentials as `auth`. */
export function apply(ctx: PluginContext, auth: Auth = credentials): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const failed = (error: unknown): void => ctx.notify("error", String(error));
  tui.commands.add({
    name: "login",
    slash: "login",
    argumentHint: "[provider]",
    description: "Connect a provider with an API key or a login",
    run: (args) => runLogin(ctx, auth, tui, args).catch(failed),
  });
  tui.commands.add({
    name: "logout",
    slash: "logout",
    argumentHint: "[provider]",
    description: "Remove what yuke stored for a provider",
    run: (args) => runLogout(ctx, auth, tui, args).catch(failed),
  });
  return undefined;
}
