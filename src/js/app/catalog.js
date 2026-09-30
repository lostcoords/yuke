// The model catalog: the providers, their models, and the model prices.
import { Refresh } from "yuke:internal/refresh";
import { root } from "yuke:internal/core";
import { client } from "yuke:internal/client";
import { errorText } from "yuke:internal/format";
import { notify } from "yuke:internal/kernel";

/** @import { Context } from "yuke:internal/ext" */
/** @typedef {{ rev: Wire.CatalogRev | null, providers: readonly Wire.ProviderInfo[], models: readonly Wire.ModelInfo[] }} CatalogState */

/** The model catalog the engine last answered. A refresh replaces its lists, so a reader holds the object and not a list. */
/** @type {CatalogState} */
export const catalog = {
  rev: null,
  providers: [],
  models: [],
};

// The status bar asks on each frame, so the answer stays until the selector or the model list changes.
/** @type {{ selector: string, models: readonly Wire.ModelInfo[] | null, model: Wire.ModelInfo | null }} */
let last = { selector: "", models: null, model: null };

/** @param {string | null | undefined} selector @returns {Wire.ModelInfo | null} */
export function modelOf(selector) {
  if (!selector) return null;
  if (last.selector !== selector || last.models !== catalog.models) last = { selector, models: catalog.models, model: catalog.models.find((x) => x.selector === selector) || null };
  return last.model;
}

/** Reads the catalog from the engine. `run()` coalesces concurrent calls and answers the catalog. */
export const catalogRefresh = new Refresh(
  () => client.catalogList(catalog.rev).then((r) => {
    if (r.type === "full") {
      catalog.rev = r.catalog_rev;
      catalog.providers = r.providers;
      catalog.models = r.models;
    }
  }),
  () => { root.invalidate(); return catalog; },
);

// Read providers.json again, then refresh the catalog. A failed reload tells the user, and the catalog still shows what the engine holds.
/** @returns {Promise<{ changed: boolean | null, catalog: CatalogState }>} */
export function reloadCatalog() {
  return client.catalogReload().then((r) => r.changed, (e) => {
    notify("error", "reload failed · " + errorText(e), "providers");
    return null;
  }).then((changed) => catalogRefresh.run().then((catalog) => ({ changed, catalog })));
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

// The catalog registration: the first read and the reload command. The chat shows the model it sends to.
export const catalogPlugin = {
  name: "catalog",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The engine is in this process, so the catalog is readable at once and needs no connect event.
      catalogRefresh.run();

      ctx.tui.command.add("catalog:reload", {
        desc: "read providers.json again",
        slash: "reload-providers",
        run: () => reloadCatalog().then(({ changed }) => {
          if (changed !== null) notify("info", changed ? "providers reloaded" : "providers unchanged", "providers");
        }),
      });
    });
  },
};
