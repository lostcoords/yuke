// yuke:catalog — the model catalog, and the model a new chat starts with.
import { root } from "yuke:core";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { newestLocalModelSession } from "yuke:sessions";

/** @typedef {{ rev: Wire.CatalogRev | null, models: readonly Wire.ModelInfo[], loading: boolean }} CatalogState */
/** @typedef {{ model: string | null, reasoning: string }} ModelDefaults */
/** @typedef {{ session: Wire.Session, activity: { context_usage?: Wire.TokenUsage } | null }} StatusEntry */
/** @typedef {{ entry?: () => StatusEntry | null }} CatalogConfig */

// One engine, one catalog. `catalog.list` answers "unchanged" while the revision holds, so a
// reopen costs no work.
/** @type {CatalogState} */
const catalog = { rev: null, models: [], loading: false };

/** @returns {CatalogState} */
export function catalogOf() {
  return catalog;
}

/** @returns {Promise<CatalogState>} */
export function loadCatalog() {
  const c = catalog;
  if (c.loading) return Promise.resolve(c);
  c.loading = true;
  return client
    .catalogList(c.rev)
    .then((r) => {
      if (r && r.type === "full") {
        c.rev = r.catalog_rev;
        c.models = r.models || [];
      }
    })
    .catch(() => {})
    .then(() => {
      c.loading = false;
      root.invalidate();
      return c;
    });
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

// The two right-hand readings that describe the model and how much context it has used.
export const catalogPlugin = {
  name: "catalog",
  /** @param {import("yuke:ext").Context} ctx @param {unknown} config @returns {void} */
  apply(ctx, config) {
    ctx.inject(["tui"], (ctx) => {
      const cfg = /** @type {CatalogConfig} */ (config || {});
      const entry = cfg.entry || (() => null);

      // The engine is in this process, so the catalog is readable at once and needs no connect event.
      loadCatalog();

      ctx.tui.status({
        side: "right",
        order: 10,
        render: () => {
          const e = entry();
          if (e && e.session && e.session.model) return e.session.model;
          return defaultModel().model || "";
        },
      });

      ctx.tui.status({
        side: "right",
        order: 20,
        render: () => {
          const e = entry();
          if (!e) return "";
          const u = e.activity ? e.activity.context_usage : null;
          if (!u || !u.input) return "";
          const win = contextWindowOf(e.session.model);
          return win ? Math.round((u.input / win) * 100) + "% ctx" : tokenLabel(u.input) + " ctx";
        },
      });
      });
},
};
