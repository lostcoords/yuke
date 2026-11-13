// The bundled plugin `login`: the provider list, the masked key field, the device login, and `/logout`.

import { apply } from "yuke:internal/bundled/login";
import type { LoginOutcome, ProviderInfo, ProviderState } from "yuke:protocol";
import { assertEquals, createFrame, type FrameTest, folder, test, waitForSettled } from "yuke:test";
import { rows } from "./rows.ts";

/** A provider `id` in `state`. */
function provider(id: string, state: ProviderState): ProviderInfo {
  return { id, name: id.toUpperCase(), state, models: [] };
}

const PROVIDERS: ProviderInfo[] = [
  provider("needs-key", { kind: "needsApiKey", variable: "NEEDS_KEY" }),
  provider("env", { kind: "ready", credential: { kind: "variable", name: "ENV_KEY" } }),
  provider("stored", { kind: "ready", credential: { kind: "storedApiKey" } }),
  provider("device", { kind: "needsLogin" }),
  provider("logged", { kind: "ready", credential: { kind: "login" } }),
  provider("local", { kind: "ready", credential: { kind: "none" } }),
];

/** The URL and the code of each fake login. */
const URL = "https://example.com/device";
const CODE = "ABCD-1234";

/** Load the plugin in `frame` on fake services. A test ends a login with `end`. */
function load(frame: FrameTest, providers: readonly ProviderInfo[] = PROVIDERS) {
  const notices: string[] = [];
  const calls: string[] = [];
  const signals: AbortSignal[] = [];
  let refusal: string | undefined;
  let startFailure: string | undefined;
  let end: (outcome: LoginOutcome) => void = () => {};
  const auth = {
    login: async (id: string, options?: { readonly signal?: AbortSignal }) => {
      calls.push(`login ${id}`);
      if (startFailure !== undefined) throw new Error(startFailure);
      const signal = options?.signal;
      if (signal === undefined) throw new Error("the plugin starts a login without a signal");
      signals.push(signal);
      const ended = new Promise<LoginOutcome>((resolve) => {
        end = resolve;
        signal.addEventListener("abort", () => resolve({ kind: "cancelled" }));
      });
      return { verificationUrl: URL, userCode: CODE, waitForEnd: () => ended };
    },
    setApiKey: async (id: string, key: string) => {
      calls.push(`set ${id} ${key}`);
      if (refusal !== undefined) throw new Error(refusal);
    },
    logout: async (id: string) => {
      calls.push(`logout ${id}`);
    },
  };
  const catalog = { list: async (options: { all?: boolean }) => ({ providers, all: options.all }) };
  const surface = frame.surface("login");
  const services: Record<string, unknown> = { tui: surface.tui, catalog };
  apply(
    {
      get: (name: string) => services[name],
      dataDir: folder(),
      notify: (level: string, text: string) => notices.push(`${level} ${text}`),
    } as never,
    auth,
  );
  frame.start();
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
    end: (outcome: LoginOutcome) => end(outcome),
    run: async (command: "login" | "logout", args?: string) => {
      surface.tui.commands.run(`login:${command}`, args);
      await waitForSettled();
      frame.draw();
      return rows(frame.frame);
    },
  };
}

/** The row of `frame` that holds `text`. */
function rowWith(frame: FrameTest, text: string): string | undefined {
  return rows(frame.frame).find((row) => row.includes(text));
}

test("/login lists each provider with its state and leaves out a provider that takes no credential", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);

  const shown = (await login.run("login")).join("\n");

  for (const [id, text] of [
    ["needs-key", "not connected"],
    ["env", "connected · $ENV_KEY"],
    ["stored", "connected · API key"],
    ["device", "not connected"],
    ["logged", "connected · login"],
  ] as const) {
    assertEquals(rowWith(frame, `· ${id}`)?.includes(text), true, shown);
  }
  assertEquals(shown.includes("LOCAL"), false);

  // A query matches the name and the id, not the state.
  frame.key("c o n n");
  assertEquals(rowWith(frame, "· device"), undefined);
});

test("a chosen key provider opens a masked field that stores the key and shows no character of it", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);
  await login.run("login");

  frame.key("e n v enter");
  await waitForSettled();
  frame.paste("  sk-secret\n");
  const typed = rows(frame.frame).join("\n");
  const title = rowWith(frame, "API key · ENV");
  // The second enter of a double press stores nothing more.
  frame.key("enter");
  frame.key("enter");
  await waitForSettled();
  frame.draw();

  assertEquals(title !== undefined, true);
  assertEquals(typed.includes("sk-secret"), false);
  assertEquals(typed.includes("•••"), true);
  assertEquals(login.calls, ["set env sk-secret"]);
  assertEquals(login.notices, ["info key saved · env"]);
  assertEquals(rowWith(frame, "API key · ENV"), undefined);
});

test("a connected provider can be picked, and esc in the field stores nothing", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);

  await login.run("login", "stored");
  frame.paste("new-key");
  frame.key("esc");
  await waitForSettled();
  frame.draw();
  const afterEscape = [...login.calls];
  const closed = rowWith(frame, "API key · STORED");
  await login.run("login", "stored");
  frame.paste("new-key");
  frame.key("enter");
  await waitForSettled();

  assertEquals([afterEscape, closed], [[], undefined]);
  assertEquals(login.calls, ["set stored new-key"]);
});

test("a refused key stays in the field with its error, and an empty field stores nothing", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);
  login.refuseWith("the key is bad");
  await login.run("login", "needs-key");

  frame.key("enter");
  await waitForSettled();
  const afterEmpty = [...login.calls];
  frame.paste("first");
  frame.key("enter");
  await waitForSettled();
  frame.draw();
  const refused = rowWith(frame, "the key is bad");
  const open = rowWith(frame, "API key · NEEDS-KEY");
  login.refuseWith(undefined);
  frame.key("enter");
  await waitForSettled();

  assertEquals(afterEmpty, []);
  assertEquals(refused !== undefined, true);
  assertEquals(open !== undefined, true);
  assertEquals(login.notices, ["info key saved · needs-key"]);
  assertEquals(login.calls, ["set needs-key first", "set needs-key first"]);
});

test("/login with a text that is no provider id stores nothing and repeats no text", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);

  await login.run("login", "stored sk-abc");
  await login.run("login", "sk-abc");
  await login.run("login", "local");
  await login.run("logout", "sk-abc");

  assertEquals(login.calls, []);
  assertEquals(login.notices.length, 4);
  assertEquals(
    login.notices.some((notice) => notice.includes("sk-abc")),
    false,
  );
  assertEquals(rowWith(frame, "Log in"), undefined);
});

test("/logout lists only what yuke stored, removes it, and names the variable of a key in the environment", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);

  const listed = (await login.run("logout")).join("\n");
  frame.key("s t o r e d enter");
  await waitForSettled();
  await login.run("logout", "env");
  await login.run("logout", "device");
  await login.run("logout", "logged");

  assertEquals(listed.includes("STORED"), true);
  assertEquals(listed.includes("LOGGED"), true);
  for (const absent of ["ENV", "NEEDS-KEY", "DEVICE", "LOCAL"]) assertEquals(listed.includes(absent), false);
  assertEquals(login.calls, ["logout stored", "logout logged"]);
  assertEquals(login.notices, [
    "info logged out · stored",
    "info env has its key in $ENV_KEY: unset the variable",
    "info yuke stores no credential for device",
    "info logged out · logged",
  ]);
});

test("/logout with nothing stored gives a notice and opens no list", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame, [provider("env", { kind: "ready", credential: { kind: "variable", name: "ENV_KEY" } })]);

  await login.run("logout");

  assertEquals(login.notices, ["info yuke stores no credential"]);
  assertEquals(rowWith(frame, "Log out"), undefined);
});

test("a login provider shows the page and the code, its keys copy each, and a connected one can log in again", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);

  const shown = (await login.run("login", "logged")).join("\n");
  frame.key("c");
  frame.key("u");

  assertEquals(login.calls, ["login logged"]);
  assertEquals(shown.includes(URL), true);
  assertEquals(shown.includes(`Code: ${CODE}`), true);
  assertEquals(shown.includes("o: open"), true);
  assertEquals(frame.copies, [CODE, URL]);
  assertEquals(login.notices, ["info code copied", "info URL copied"]);
  frame.key("esc");
  await waitForSettled();
});

test("each end of a device login closes the dialog with its notice, and esc cancels the login with no notice", async () => {
  for (const [outcome, notice] of [
    [{ kind: "succeeded" }, "info logged in · device"],
    [{ kind: "failed", error: "denied" }, "error the login failed: denied"],
    [{ kind: "cancelled" }, "info login cancelled"],
  ] as const) {
    using frame = createFrame({ width: 70, height: 16 });
    const login = load(frame);
    await login.run("login", "device");

    login.end(outcome);
    await waitForSettled();
    frame.draw();

    assertEquals(login.notices, [notice]);
    assertEquals(rowWith(frame, "Log in · DEVICE"), undefined);
  }

  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);
  await login.run("login", "device");
  frame.key("esc");
  await waitForSettled();

  assertEquals(login.signals[0]?.aborted, true);
  assertEquals(login.notices, []);
});

test("a login that does not start closes the dialog with a notice", async () => {
  using frame = createFrame({ width: 70, height: 16 });
  const login = load(frame);
  login.failStartWith("no network");

  await login.run("login", "device");

  assertEquals(login.notices, ["error the login failed: Error: no network"]);
  assertEquals(rowWith(frame, "Log in · DEVICE"), undefined);
});
