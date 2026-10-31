/**
 * The bundled plugin `plugins`. Its command `plugins:open` lists the plugins of `config.json` in a picker, with the
 * locked commit of each Git plugin and whether each plugin is installed and loaded. Enter checks the chosen Git plugin.
 * `plugins:sync` installs the locked commits and locks the new Git plugins. `plugins:update` checks each Git plugin. A
 * check opens a review of the new commits: Enter writes them into `plugins.lock`, and Esc keeps the lock. A new commit
 * loads at the next `/reload`.
 */

import { bottom } from "yuke:internal/tui/layout";
import type { PluginContext, PluginManager } from "yuke:plugins";
import type { ManagedPlugin, PluginChange, PluginTarget } from "yuke:protocol";
import { Picker, strokeOf, type TextDocument, TextView, type Tui, type View } from "yuke:tui";

/** The overlay has at most this count of rows, with its head row. */
const ROWS = 13;

const HEAD = Object.freeze({ dim: true });

/** The rows that each scroll key of the review moves. A page leaves one row of the last page. */
const SCROLL: Readonly<Record<string, number>> = { up: -1, down: 1, page_up: -(ROWS - 3), page_down: ROWS - 3 };

export function apply(ctx: PluginContext): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  const plugins = ctx.get("plugins");
  const report = (what: string) => (error: unknown) => ctx.notify("error", `${what}: ${String(error)}`);
  tui.commands.add({
    name: "open",
    description: "List the plugins of config.json, their commits, and their state",
    run: () => open(ctx, tui, plugins).catch(report("the plugins did not load")),
  });
  tui.commands.add({
    name: "sync",
    description: "Install the locked Git plugins, and lock the new ones",
    run: () => sync(ctx, plugins).catch(report("the sync failed")),
  });
  tui.commands.add({
    name: "update",
    description: "Check each Git plugin for a new commit of its ref",
    run: () => review(ctx, tui, plugins, "all").catch(report("the check failed")),
  });
  return undefined;
}

/** The first seven digits of `commit`. */
function short(commit: string): string {
  return commit.slice(0, 7);
}

/** The state of `plugin` on disk and in the runtime, for the detail of its row. */
function stateOf(plugin: ManagedPlugin): string {
  const loaded = plugin.loaded ? "loaded" : "not loaded";
  switch (plugin.state) {
    case "local":
      return `local · ${loaded}`;
    case "not_locked":
      return "not locked: /plugins:sync";
    case "not_installed":
      return `${short(plugin.commit)} not installed: /plugins:sync`;
    case "installed":
      return `${short(plugin.commit)} · ${loaded}`;
  }
}

/** The mark of `plugin`: loaded, not loaded, or a problem that a sync fixes. */
function markOf(plugin: ManagedPlugin): string {
  if (plugin.state === "not_locked" || plugin.state === "not_installed") return "!";
  return plugin.loaded ? "●" : "○";
}

/** Open the list of the plugins over the focused pane. Enter on a Git plugin with a name checks it. */
async function open(ctx: PluginContext, tui: Tui, plugins: PluginManager): Promise<void> {
  const listed = await plugins.list();
  const picker = new Picker<ManagedPlugin>({
    items: listed.plugins,
    key: (plugin) => plugin.item,
    label: (plugin) => `${markOf(plugin)} ${plugin.name ?? "?"}`,
    detail: (plugin) => `${plugin.item} · ${stateOf(plugin)}`,
    choose: (plugin) => {
      // Only an installed Git plugin has a commit to compare and a name to check.
      const name = plugin.name;
      if (plugin.state !== "installed" || typeof name !== "string") return;
      overlay.close();
      review(ctx, tui, plugins, { names: [name] }).catch((error: unknown) =>
        ctx.notify("error", `the check failed: ${String(error)}`),
      );
    },
    cancel: () => overlay.close(),
  });
  const view: View = {
    layout: (size) => [
      { view: picker, rect: { column: 0, row: 1, width: size.width, height: Math.max(0, size.height - 1) } },
    ],
    draw: (canvas) => canvas.text(1, 0, "enter: check a Git plugin · /plugins:sync · /plugins:update", HEAD),
    initialFocus: picker.input,
  };
  const overlay = tui.overlay(() => view, { place: (size) => bottom(size, ROWS) });
}

/** Install the locked commits and lock the new Git plugins. A notice tells the result. */
async function sync(ctx: PluginContext, plugins: PluginManager): Promise<void> {
  ctx.notify("info", "the sync of the Git plugins runs");
  const synced = await plugins.sync({ signal: ctx.signal });
  ctx.notify("info", synced.written ? "plugins.lock written: run /reload" : "each Git plugin is at its locked commit");
}

/** A document of one text item for each entry of `items`: a label and its lines. */
function documentOf(items: readonly { readonly label: string; readonly lines: readonly string[] }[]): TextDocument {
  return {
    key: "plugins-review",
    items: items.map((item, index) => ({
      key: String(index),
      sections: [
        { key: "label", kind: "label", text: item.label },
        ...(item.lines.length === 0 ? [] : [{ key: "log", kind: "text" as const, text: item.lines.join("\n") }]),
      ],
    })),
  };
}

/** The review of `changes`: each plugin with its move and the log of the move. */
function reviewOf(changes: readonly PluginChange[]): TextDocument {
  return documentOf(
    changes.map((change) => ({
      label: `${change.name}  ${short(change.old)} → ${short(change.new)}`,
      lines:
        "commits" in change.log ? change.log.commits.map((line) => `  ${line}`) : [`  no log: ${change.log.error}`],
    })),
  );
}

/**
 * Check the Git plugins of `target` in an overlay. The overlay opens at once, and its close (Esc) stops the check. With
 * changes, Enter writes them into `plugins.lock`.
 */
async function review(ctx: PluginContext, tui: Tui, plugins: PluginManager, target: PluginTarget): Promise<void> {
  let changes: readonly PluginChange[] | undefined;
  const text = new TextView({ document: documentOf([{ label: "the check of the Git plugins runs", lines: [] }]) });
  const view: View = {
    layout: (size) => [
      { view: text, rect: { column: 0, row: 0, width: size.width, height: Math.max(0, size.height - 1) } },
    ],
    draw: (canvas) => {
      const keys =
        changes !== undefined && changes.length > 0 ? "enter: write plugins.lock · esc: keep it" : "esc: close";
      canvas.text(1, canvas.height - 1, keys, HEAD);
    },
    initialFocus: text,
  };
  const overlay = tui.overlay(() => view, { place: (size) => bottom(size, ROWS) });
  text.extend(overlay.signal).onKey((event) => {
    const stroke = strokeOf(event);
    // A text view has no keys of its own, so the review scrolls a long log here.
    const rows = SCROLL[stroke];
    if (rows !== undefined) {
      text.scroll.scrollBy(rows);
      tui.requestFrame();
      return true;
    }
    if (stroke !== "enter" || changes === undefined || changes.length === 0) return false;
    const chosen = changes;
    overlay.close();
    plugins.apply(chosen).then(
      (applied) =>
        ctx.notify(
          "info",
          applied.written ? "plugins.lock written: run /reload to load the new commits" : "plugins.lock unchanged",
        ),
      (error: unknown) => ctx.notify("error", `plugins.lock did not write: ${String(error)}`),
    );
    return true;
  }, "beforeKeymap");
  try {
    changes = (await plugins.check(target, { signal: overlay.signal })).changes;
  } catch (error) {
    // A close of the overlay stops the check, and the user saw it close.
    if (overlay.signal.aborted) return;
    overlay.close();
    throw error;
  }
  text.setDocument(
    changes.length === 0
      ? documentOf([{ label: "each Git plugin is at the newest commit of its ref", lines: [] }])
      : reviewOf(changes),
  );
  tui.requestFrame();
}
