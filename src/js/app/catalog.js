// yuke:catalog — the model catalog, and the model a new chat starts with.
import { root } from "yuke:core";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { newestLocalModelSession } from "yuke:sessions";

/** @typedef {{ rev: Wire.CatalogRev | null, providers: readonly Wire.ProviderInfo[], models: readonly Wire.ModelInfo[], loading: boolean, again: boolean }} CatalogState */
/** @typedef {{ model: string | null, reasoning: string }} ModelDefaults */
/** @typedef {{ session: Wire.Session, activity: { context_usage?: Wire.TokenUsage } | null }} StatusEntry */
/** @typedef {{ entry?: () => StatusEntry | null }} CatalogConfig */

// One engine, one catalog. `catalog.list` answers "unchanged" while the revision holds, so a reopen costs no work.
/** @type {CatalogState} */
const catalog = { rev: null, providers: [], models: [], loading: false, again: false };

/** @returns {CatalogState} */
export function catalogOf() {
  return catalog;
}

// A load during a load runs one more after it, so a change that lands mid-flight still reaches the catalog.
/** @returns {Promise<CatalogState>} */
export function loadCatalog() {
  const c = catalog;
  if (c.loading) {
    c.again = true;
    return Promise.resolve(c);
  }
  c.loading = true;
  return client
    .catalogList(c.rev)
    .then((r) => {
      if (r && r.type === "full") {
        c.rev = r.catalog_rev;
        c.providers = r.providers || [];
        c.models = r.models || [];
      }
    })
    .catch(() => {})
    .then(() => {
      c.loading = false;
      root.invalidate();
      if (!c.again) return c;
      c.again = false;
      return loadCatalog();
    });
}

// Read providers.json again, then refresh the catalog. A failed reload still refreshes what the engine holds.
/** @returns {Promise<CatalogState>} */
export function reloadCatalog() {
  return client.catalogReload().catch(() => {}).then(loadCatalog);
}

// The state of one provider, or null when the catalog does not name it.
/** @param {string} providerId @returns {Wire.ProviderState | null} */
export function providerState(providerId) {
  const p = catalog.providers.find((x) => x.id === providerId);
  return p ? p.state : null;
}

// The words a row shows for a provider state. A ready provider shows nothing, so only a problem draws.
/** @param {Wire.ProviderState | null} state @param {boolean} [canLogin] @returns {string} */
export function providerStateLabel(state, canLogin = true) {
  switch (state) {
    case "needs_credential": return canLogin ? "needs login" : "needs key";
    case "needs_route": return "needs route";
    case "expired": return "expired";
    default: return "";
  }
}

// The context window of one model, or 0 when the catalog does not name it.
/** @param {string | null | undefined} modelId @returns {number} */
export function contextWindowOf(modelId) {
  if (!modelId) return 0;
  const m = catalog.models.find((x) => x.selector === modelId);
  return m && m.context_window ? m.context_window : 0;
}

// The model a new chat starts with; `session.patch` is not implemented, so a choice cannot move an open session.
/** @type {ModelDefaults} */
const chatDefaults = { model: null, reasoning: "" };

/** @param {Wire.ModelInfo} model @param {string} reasoning @returns {void} */
export function chooseModel(model, reasoning) {
  chatDefaults.model = model.selector;
  chatDefaults.reasoning = reasoning;
  notice.show("model · " + model.name + (reasoning ? " · " + reasoning : ""));
  root.invalidate();
}

// Without a choice this run, the newest session names the model and reasoning, so a restart keeps working.
/** @returns {ModelDefaults} */
export function defaultModel() {
  if (chatDefaults.model) return chatDefaults;
  const s = newestLocalModelSession();
  if (s && s.model) return { model: s.model, reasoning: s.reasoning };
  return chatDefaults;
}

// Round a token count to a short label. The catalog is not in the TUI, so this is not a percentage.
/** @param {number} n @returns {string} */
export function tokenLabel(n) {
  if (n < 1000) return String(n);
  return (n / 1000).toFixed(n < 10000 ? 1 : 0) + "k";
}

// The model reading on the right of the status bar. `yuke:context` shows the usage beside it.
export const catalogPlugin = {
  name: "catalog",
  /** @param {import("yuke:ext").Context} ctx @param {unknown} config @returns {void} */
  apply(ctx, config) {
    ctx.inject(["tui"], (ctx) => {
      const cfg = /** @type {CatalogConfig} */ (config || {});
      const entry = cfg.entry || (() => null);

      // The engine is in this process, so the catalog is readable at once and needs no connect event.
      loadCatalog();

      ctx.tui.command(null, {
        "catalog:reload": () => client.catalogReload().then(
          (r) => { notice.show(r.changed ? "providers reloaded" : "providers unchanged"); return loadCatalog(); },
          (e) => notice.show("reload failed · " + e.message),
        ),
      }, {
        "catalog:reload": { title: "Reload providers", description: "read providers.json again", slash: "reload" },
      });

      ctx.tui.status({
        side: "right",
        order: 10,
        render: () => {
          const e = entry();
          if (e && e.session && e.session.model) return e.session.model;
          return defaultModel().model || "";
        },
      });
      });
},
};
