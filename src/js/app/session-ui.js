// The session pickers: the model, its effort, and the session finder. The sessions plugin opens them and passes their data.
import { command } from "yuke:internal/core";
import { notify } from "yuke:internal/kernel";
import { ui } from "yuke:internal/ui";
import { catalogOf, reloadCatalog, providerState, providerStateLabel } from "yuke:internal/catalog";

/** @import { Composer } from "yuke:internal/ui" */
/** @import { InjectContext } from "./types/ext.js" */
/** @import { SessionPane, SessionRow } from "yuke:internal/session" */

// Load the catalog, then pick a model and its effort for `pane`. A `query` names the model and skips the picker.
/** @param {InjectContext} ctx @param {SessionPane} pane @param {string | null} currentId @param {string} [query] @returns {void} */
export function openModelPicker(ctx, pane, currentId, query) {
  const show = () => {
    // Code-unit order: localeCompare NFC-normalizes and traps in ReleaseSafe QuickJS.
    const models = catalogOf().models.slice().sort((a, b) => (a.provider < b.provider ? -1 : a.provider > b.provider ? 1 : 0) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    if (models.length === 0) return notify("info", "no model in the catalog", "model");
    if (query) {
      const m = models.find((x) => x.selector === query || x.id === query || x.name === query);
      if (m) {
        if (modelAvailable(m)) pane.session.setModel(m, m.default_reasoning || m.reasoning_levels[0] || "");
      }
      else notify("info", "no model named " + query, "model");
      return;
    }
    const p = ui.pick({
      title: "select a model",
      footer: "type to filter · ↵ select · esc close",
      border: "none",
      panelGroup: "UIFloat",
      anchor: pane.composer ? () => /** @type {Composer} */ (pane.composer).rect : null,
      maxRows: 6,
      items: models,
      // The catalog owns the selector format. The picker keys on it and never builds one.
      key: (m) => m.selector,
      filterText: m => m.provider + " " + m.name + " " + m.id,
      // A model with a provider that cannot serve shows the reason before the user starts a run.
      format: m => {
        const label = providerStateLabel(providerState(m.provider));
        return label ? { text: m.name, right: m.provider + " · " + label, group: "UIDim" } : { text: m.name, right: m.provider };
      },
      onAccept: m => {
        if (modelAvailable(m)) pickReasoning(ctx, m, pane);
      },
    });
    ctx.tui.overlay(p.win);
    p.content.list.selectKey(currentId);
  };
  // Reload the file before the picker lists, so a login from another process shows.
  reloadCatalog().then(show);
}

/** @param {Wire.ModelInfo} model @returns {boolean} */
function modelAvailable(model) {
  const state = providerState(model.provider);
  if (state === "needs_credential") command.perform("auth:login", model.provider);
  else if (state === "needs_route") notify("warn", model.provider + " needs a route in providers.json", "model");
  else return true;
  return false;
}

// A model with at most one level needs no second step, so the pick ends there.
/** @param {InjectContext} ctx @param {Wire.ModelInfo} model @param {SessionPane} pane @returns {void} */
function pickReasoning(ctx, model, pane) {
  const session = pane.session;
  const levels = model.reasoning_levels;
  if (levels.length < 2) {
    session.setModel(model, model.default_reasoning || levels[0] || "");
    return;
  }
  const composer = pane.composer;
  const step = ui.pick({
    title: model.name + " · effort",
    footer: "↵ select · esc close",
    border: "none",
    panelGroup: "UIFloat",
    anchor: composer ? () => composer.rect : null,
    maxRows: 6,
    items: levels.map((id) => ({ id })),
    key: l => l.id,
    filterText: l => l.id,
    format: l => ({ text: l.id }),
    onAccept: l => session.setModel(model, l.id),
  });
  ctx.tui.overlay(step.win);
  step.content.list.selectKey(model.default_reasoning || levels[0]);
}

// The session finder fuzzy-searches `rows` by title and passes the chosen id to `open`. `activityOf` answers the live activity of an open session.
/** @param {InjectContext} ctx @param {SessionRow[]} rows @param {(id: string) => Wire.SessionActivity | null | undefined} activityOf @param {(id: string) => void} open @returns {void} */
export function openSessionFinder(ctx, rows, activityOf, open) {
  if (rows.length === 0) {
    notify("info", "no sessions yet", "session");
    return;
  }
  const p = ui.pick({
    title: "sessions",
    footer: "type to filter · ↵ select · esc close",
    border: "rounded",
    width: max => Math.round(max * 0.6),
    height: max => Math.round(max * 0.5),
    items: rows,
    key: r => r.id,
    filterText: r => r.title,
    // An open session reads its live activity; the rest shows what the list reported. A working session shows "●".
    format: r => ({ text: r.title, right: (activityOf(r.id) || r.activity).state.type === "idle" ? "" : "●" }),
    onAccept: r => open(r.id),
  });
  ctx.tui.overlay(p.win);
}
