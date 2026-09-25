// The model catalog, and the model a new chat starts with.
import { Refresh } from "yuke:internal/refresh";
import { root } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { client } from "yuke:internal/client";
import { notice } from "yuke:internal/notice";
import { newestLocalModelSession } from "yuke:internal/sessions";
import { errorText } from "yuke:internal/format";

/** @import { Context } from "yuke:internal/ext" */
/** @typedef {{ rev: Wire.CatalogRev | null, providers: readonly Wire.ProviderInfo[], models: readonly Wire.ModelInfo[], loading: boolean }} CatalogState */
/** @typedef {{ model: string | null, reasoning: string }} ModelDefaults */
/** @typedef {{ session: Wire.Session, activity: { context_usage?: Wire.TokenUsage } | null }} StatusEntry */
/** @typedef {{ entry?: () => StatusEntry | null }} CatalogConfig */

/** @type {CatalogState} */
const catalog = {
  rev: null,
  providers: [],
  models: [],
  get loading() { return refresh.loading; },
};

/** @returns {CatalogState} */
export function catalogOf() {
  return catalog;
}

/** @param {string | null | undefined} selector @returns {Wire.ModelInfo | null} */
export function modelOf(selector) {
  if (!selector) return null;
  return catalog.models.find((x) => x.selector === selector) || null;
}

const refresh = new Refresh(
  () => client.catalogList(catalog.rev).then((r) => {
    if (r.type === "full") {
      catalog.rev = r.catalog_rev;
      catalog.providers = r.providers;
      catalog.models = r.models;
    }
  }),
  () => { root.invalidate(); return catalog; },
);

/** @returns {Promise<CatalogState>} */
export function loadCatalog() {
  return refresh.run();
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
    default: return "";
  }
}

// The context window of one model, or 0 when the catalog does not name it.
/** @param {string | null | undefined} modelId @returns {number} */
export function contextWindowOf(modelId) {
  const m = modelOf(modelId);
  return m && m.context_window ? m.context_window : 0;
}

// The model a new chat starts with. A named session moves to the same choice.
/** @type {ModelDefaults} */
const chatDefaults = { model: null, reasoning: "" };

/** @param {Wire.ModelInfo} model @param {string} reasoning @param {string | null} [sessionId] @returns {void} */
export function chooseModel(model, reasoning, sessionId = null) {
  const previous = { ...chatDefaults };
  chatDefaults.model = model.selector;
  chatDefaults.reasoning = reasoning;
  notice.show("model · " + model.name + (reasoning ? " · " + reasoning : ""));
  // A pane that holds an attachment may have something to say about the model it now sends to.
  events.emit("model.changed", { model, sessionId });
  root.invalidate();
  if (!sessionId) return;
  // A run in flight keeps the settings it started with, so the move lands on the next turn.
  client.sessionPatch(sessionId, { model: model.selector, reasoning }).then(() => root.invalidate()).catch((e) => {
    // The engine refused, so the default must not keep a choice the engine rejected.
    Object.assign(chatDefaults, previous);
    notice.show("model · " + errorText(e));
    root.invalidate();
  });
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

// The model reading on the right of the status bar. `yuke:internal/context` shows the usage beside it.
/** @param {CatalogConfig} [cfg] */
export function modelCatalog(cfg = {}) {
  return {
  name: "catalog",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      const entry = cfg.entry || (() => null);

      // The engine is in this process, so the catalog is readable at once and needs no connect event.
      loadCatalog();

      ctx.tui.command(null, {
        "catalog:reload": () => client.catalogReload().then(
          (r) => { notice.show(r.changed ? "providers reloaded" : "providers unchanged"); return loadCatalog(); },
          (e) => notice.show("reload failed · " + errorText(e)),
        ),
      }, {
        "catalog:reload": { title: "Reload providers", description: "read providers.json again", slash: "reload-providers" },
      });

      ctx.tui.status({
        side: "right",
        order: 10,
        render: () => {
          const e = entry();
          if (e && e.session.model) return e.session.model;
          return defaultModel().model || "";
        },
      });
      });
},
  };
}
