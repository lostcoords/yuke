// yuke:auth — /login and /logout: the provider list, the device-code dialog, and the API key prompt.
import { root, copy, strokeOf } from "yuke:core";
import { ui, Window, Prompt } from "yuke:ui";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { exec } from "yuke:exec";
import { loadCatalog, providerState, providerStateLabel, reloadCatalog } from "yuke:catalog";

/** @typedef {import("yuke:ext").InjectContext} Ctx */
/** @typedef {Wire.AuthProvider & { state: Wire.ProviderState | null }} ProviderRow */

// The state a login row shows. A key provider needs a key where a grant provider needs a login.
/** @param {ProviderRow} p @returns {string} */
function stateLabel(p) {
  if (p.state === "needs_credential" && !p.can_login) return "needs key";
  return p.state === "ready" ? "ready" : providerStateLabel(p.state);
}

/** @param {Wire.AuthProvider} p @returns {string} */
function kindLabel(p) {
  return p.can_login ? "account" : "api key";
}

// Read the providers after a reload, so a login from another process shows.
/** @returns {Promise<ProviderRow[]>} */
function providerRows() {
  return reloadCatalog()
    .then(() => client.authList())
    .then((r) => r.providers.map((p) => ({ ...p, state: providerState(p.provider_id) })));
}

// Open a URL with the OS opener. The shell line quotes it, so a provider URL never becomes shell syntax.
/** @param {string} url @returns {void} */
function openUrl(url) {
  const quoted = "'" + url.replace(/'/g, "'\\''") + "'";
  exec("open " + quoted + " 2>/dev/null || xdg-open " + quoted + " 2>/dev/null").catch(() => {});
}

// The device-code step: the URL to open and the code to enter. The engine polls; this window only waits.
class DeviceDialog {
  /** @param {Wire.AuthLoginResult} start */
  constructor(start) {
    this.start = start;
    /** @type {(() => void) | null} */
    this.onCancel = null;
  }

  /** @param {Window} win @returns {void} */
  draw(win) {
    win.winText(0, 0, "open  ", "UIDim");
    win.winText(6, 0, this.start.verification_url, "UIQuery");
    win.winText(0, 1, "code  ", "UIDim");
    win.winText(6, 1, this.start.user_code, "UITitle");
    win.winText(0, 2, "waiting for the provider…", "UIDim");
  }

  /** @param {HostEvent} event @returns {boolean} */
  onKey(event) {
    if (event.type !== "key") return true;
    const s = strokeOf(event);
    if (s === "esc" && this.onCancel) this.onCancel();
    else if (s === "c") copy(this.start.user_code, "code");
    else if (s === "o") openUrl(this.start.verification_url);
    return true;
  }
}

/** @param {ProviderRow} p @param {Wire.AuthLoginOutcome} outcome @returns {void} */
function finishLogin(p, outcome) {
  if (outcome.type === "succeeded") {
    notice.show("logged in · " + p.provider_id);
    loadCatalog();
  } else if (outcome.type === "canceled") notice.show("login canceled");
  else notice.show("login failed · " + outcome.message);
}

// Start the device flow, then hold the dialog until the engine reports the one terminal outcome.
/** @param {Ctx} ctx @param {ProviderRow} p @returns {void} */
function deviceLogin(ctx, p) {
  client.authLogin(p.provider_id).then((start) => {
    const dialog = new DeviceDialog(start);
    const win = new Window({
      title: "login · " + p.provider_id,
      footer: "o open · c copy code · esc cancel",
      border: "rounded",
      width: 0.6,
      height: 5,
      content: dialog,
    });
    root.pushOverlay(win);
    const release = ctx.tui.overlay(win);
    // The digest carries the auth events whole, so the outcome for this login id reads here.
    const off = ctx.on("auth.login_finished", /** @param {import("yuke:engine-native").EngineEvent} ev */ (ev) => {
      const notes = ev.type === "index" && ev.auth ? ev.auth : [];
      const note = notes.find((n) => n.method === "auth.login_finished" && n.params.login_id === start.login_id);
      if (!note) return;
      off();
      release();
      finishLogin(p, /** @type {Wire.AuthLoginFinishedData} */ (note.params).outcome);
    });
    dialog.onCancel = () => {
      off();
      release();
      client.authCancelLogin(start.login_id).catch(() => {});
      notice.show("login canceled");
    };
  }, (e) => notice.show("login failed · " + e.message));
}

// Ask for a key behind a mask, then store it. The engine announces the catalog change on its own.
/** @param {Ctx} ctx @param {ProviderRow} p @returns {void} */
function keyLogin(ctx, p) {
  const prompt = new Prompt({
    placeholder: "paste the API key",
    mask: true,
    settle: (value) => {
      release();
      if (!value) return;
      client.authSetApiKey(p.provider_id, value).then(
        () => {
          notice.show("key saved · " + p.provider_id);
          return loadCatalog();
        },
        (e) => notice.show("key rejected · " + e.message),
      );
    },
  });
  const win = new Window({ title: "api key · " + p.provider_id, footer: "↵ save · esc cancel", border: "rounded", width: 0.6, height: 3, content: prompt });
  root.pushOverlay(win);
  const release = ctx.tui.overlay(win);
}

/** @param {Ctx} ctx @param {ProviderRow} p @returns {void} */
function startLogin(ctx, p) {
  if (p.can_login) deviceLogin(ctx, p);
  else keyLogin(ctx, p);
}

// `/login` lists every provider with its state; `/login codex` starts that one.
/** @param {Ctx} ctx @param {string} [query] @returns {void} */
function openLogin(ctx, query) {
  providerRows().then((rows) => {
    if (query) {
      const p = rows.find((x) => x.provider_id === query);
      if (p) startLogin(ctx, p);
      else notice.show("no provider named " + query);
      return;
    }
    const picked = ui.pick({
      title: "login",
      footer: "type to filter · ↵ select · esc close",
      border: "rounded",
      width: 0.6,
      height: 0.5,
      items: rows,
      key: (p) => p.provider_id,
      filterText: (p) => p.provider_id,
      format: (p) => ({ text: p.provider_id, detail: kindLabel(p), right: stateLabel(p) }),
      onAccept: (p) => startLogin(ctx, p),
    });
    ctx.tui.overlay(picked.win);
  }, (e) => notice.show("login failed · " + e.message));
}

// `/logout` lists the providers that hold a credential; `/logout codex` drops that one.
/** @param {Ctx} ctx @param {string} [query] @returns {void} */
function openLogout(ctx, query) {
  client.authList().then((r) => {
    const rows = r.providers.filter((p) => p.credential_kind != null);
    /** @param {Wire.AuthProvider} p */
    const remove = (p) => client.authRemove(p.provider_id).then(
      () => {
        notice.show("logged out · " + p.provider_id);
        return loadCatalog();
      },
      (e) => notice.show("logout failed · " + e.message),
    );
    if (query) {
      const p = rows.find((x) => x.provider_id === query);
      if (p) remove(p);
      else notice.show("no credential for " + query);
      return;
    }
    if (rows.length === 0) {
      notice.show("no credential to remove");
      return;
    }
    const picked = ui.pick({
      title: "logout",
      footer: "type to filter · ↵ remove · esc close",
      border: "rounded",
      width: 0.6,
      height: 0.5,
      items: rows,
      key: (p) => p.provider_id,
      filterText: (p) => p.provider_id,
      format: (p) => ({ text: p.provider_id, detail: p.credential_kind === "oauth" ? "account" : "api key" }),
      onAccept: remove,
    });
    ctx.tui.overlay(picked.win);
  }, (e) => notice.show("logout failed · " + e.message));
}

export const authPlugin = {
  name: "auth",
  /** @param {import("yuke:ext").Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      ctx.tui.command(null, {
        "auth:login": (/** @type {string | undefined} */ query) => openLogin(ctx, query),
        "auth:logout": (/** @type {string | undefined} */ query) => openLogout(ctx, query),
      }, {
        "auth:login": { title: "Login", description: "sign in to a provider", slash: "login", args: true },
        "auth:logout": { title: "Logout", description: "forget a provider credential", slash: "logout", args: true },
      });
    });
  },
};
