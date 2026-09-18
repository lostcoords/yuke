// yuke:auth — /login and /logout: the provider list, the device-code dialog, and the API key prompt.
import { copy, text } from "yuke:core";
import { clip } from "yuke:text-input";
import { strokeOf } from "yuke:keys";
import { ui } from "yuke:ui";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { exec } from "yuke:exec";
import { loadCatalog, providerState, providerStateLabel, reloadCatalog } from "yuke:catalog";

/** @import { Context } from "yuke:ext" */
/** @import { InjectContext as Ctx } from "./types/ext.js" */
/** @typedef {Wire.AuthProvider & { state: Wire.ProviderState | null }} ProviderRow */

/** @param {ProviderRow} p @returns {string} */
function stateLabel(p) {
  return p.state === "ready" ? "ready" : providerStateLabel(p.state, p.can_login);
}

/** @param {Wire.AuthProvider} p @returns {string} */
function kindLabel(p) {
  return p.can_login ? "account" : "api key";
}

// One picker over provider rows. Login and logout differ only in the rows, the footer verb, and the action.
/** @template {Wire.AuthProvider} T @param {Ctx} ctx @param {string} title @param {string} verb @param {T[]} rows @param {(p: T) => string} right @param {(p: T) => void} onAccept @returns {void} */
function pickProvider(ctx, title, verb, rows, right, onAccept) {
  const picked = ui.pick({
    title,
    footer: "type to filter · ↵ " + verb + " · esc close",
    border: "rounded",
    width: max => Math.round(max * 0.6),
    height: max => Math.round(max * 0.5),
    items: rows,
    key: (p) => p.provider_id,
    filterText: (p) => p.provider_id,
    format: (p) => ({ text: p.provider_id, detail: kindLabel(p), right: right(p) }),
    onAccept,
  });
  ctx.tui.overlay(picked.win);
}

// Read the providers after a reload, so a login from another process shows.
/** @returns {Promise<ProviderRow[]>} */
function providerRows() {
  return reloadCatalog()
    .then(() => client.authList())
    .then((r) => r.providers.map((p) => ({ ...p, state: providerState(p.provider_id) })));
}

// Open a URL with the OS opener; the quote keeps the URL out of shell syntax, and `setsid -f` keeps the browser out of the group that `exec` ends.
/** @param {string} url @returns {void} */
function openUrl(url) {
  const quoted = "'" + url.replace(/'/g, "'\\''") + "'";
  exec("open " + quoted + " 2>/dev/null || setsid -f xdg-open " + quoted + " >/dev/null 2>&1").catch(() => {});
}

// The device-code step: the URL to open and the code to enter. The engine polls; this window only waits.
export class DeviceDialog {
  /** @param {Wire.AuthLoginResult} start */
  constructor(start) {
    this.start = start;
    /** @type {(() => void) | null} */
    this.onCancel = null;
    /** @type {{ x: number, y: number, w: number, h: number }} */
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** @param {{ x: number, y: number, w: number, h: number }} rect @returns {void} */
  layout(rect) {
    this.rect = rect;
  }

  /** @param {boolean} [_focused] @returns {void} */
  draw(_focused = false) {
    const { x, y, w, h } = this.rect;
    if (w <= 0 || h <= 0) return;
    text(x, y, clip("open  ", w), "UIDim");
    if (w > 6) text(x + 6, y, clip(this.start.verification_url, w - 6), "UIQuery");
    if (this.rect.h <= 1) return;
    text(x, y + 1, clip("code  ", w), "UIDim");
    if (w > 6) text(x + 6, y + 1, clip(this.start.user_code, w - 6), "UITitle");
    if (this.rect.h <= 2) return;
    text(x, y + 2, clip("waiting for the provider…", w), "UIDim");
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

// The shared interaction owns the dialog; this call owns the provider login.
/** @param {Ctx} ctx @param {ProviderRow} p @returns {Promise<void>} */
async function deviceLogin(ctx, p) {
  if (!ctx.scope.alive) return;
  const login = client.authLoginTracked(p.provider_id);
  let loginId = "";
  let finished = false;
  const release = ctx.effect(() => login.dispose);
  try {
    const start = await login.start;
    loginId = start.login_id;
    if (!ctx.scope.alive) return;
    const outcome = await ctx.interaction.deviceLogin(start, login.outcome);
    finished = outcome !== undefined;
    if (ctx.scope.alive) {
      if (outcome) finishLogin(p, outcome);
      else notice.show("login canceled");
    }
  } catch (error) {
    if (ctx.scope.alive) notice.show("login failed · " + String(error));
  } finally {
    release();
    if (loginId && !finished) await client.authCancelLogin(loginId).catch(() => {});
  }
}

/** @param {Ctx} ctx @param {ProviderRow} p @returns {Promise<void>} */
async function keyLogin(ctx, p) {
  try {
    const key = await ctx.interaction.input("api key · " + p.provider_id, "paste the API key", { secret: true });
    if (!key || !ctx.scope.alive) return;
    await client.authSetApiKey(p.provider_id, key);
    if (ctx.scope.alive) {
      notice.show("key saved · " + p.provider_id);
      await loadCatalog();
    }
  } catch (error) {
    if (ctx.scope.alive) notice.show("key rejected · " + String(error));
  }
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
    pickProvider(ctx, "login", "select", rows, stateLabel, (p) => startLogin(ctx, p));
  }, (e) => notice.show("login failed · " + e.message));
}

// `/logout` lists the providers that hold a credential; `/logout codex` drops that one.
/** @param {Ctx} ctx @param {string} [query] @returns {void} */
function openLogout(ctx, query) {
  client.authList().then((r) => {
    const rows = r.providers.filter((p) => p.credential_kind != null);
    // A key the environment supplies is not in the file, so the engine cannot remove it and says so.
    /** @param {Wire.AuthProvider} p */
    const remove = (p) => client.authRemove(p.provider_id).then(
      () => {
        notice.show("logged out · " + p.provider_id);
        return loadCatalog();
      },
      (e) => notice.show(e.code === "unknown_provider" ? p.provider_id + " has its key in the environment · unset the variable" : "logout failed · " + e.message),
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
    pickProvider(ctx, "logout", "remove", rows, () => "", remove);
  }, (e) => notice.show("logout failed · " + e.message));
}

export const authPlugin = {
  name: "auth",
  /** @param {Context} ctx @returns {void} */
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
