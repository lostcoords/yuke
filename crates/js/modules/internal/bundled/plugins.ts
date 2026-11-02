/**
 * The bundled plugin `plugins`. Its command `plugins:open` shows a dashboard of the plugins of `config.json` in three
 * sections: the plugins that a sync needs, the installed Git plugins, and the local plugins. Its keys sync, update,
 * add, remove, search, and reload. `plugins:sync` and `plugins:update` run the same actions without the dashboard. An
 * update shows a review of the new commits first, and a new commit loads at the next reload.
 */

import type { PluginContext, PluginManager } from "yuke:plugins";
import type { AddPluginParams, ManagedPlugin, PluginChange, PluginTarget } from "yuke:protocol";
import {
  type Canvas,
  type KeyEvent,
  Picker,
  strokeOf,
  type TextDocument,
  TextEditor,
  TextView,
  type Tui,
  type View,
} from "yuke:tui";

const TITLE = "plugins.title";
const DETAIL = "plugins.detail";
const SELECTED = "plugins.selected";

/** The look of the list of plugins. */
const STYLES = {
  [TITLE]: { bold: true },
  [DETAIL]: { dim: true },
  [SELECTED]: { fg: "surfaceFg", bg: "accentMuted" },
} as const;

export function apply(ctx: PluginContext): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  tui.styles.set(STYLES);
  const plugins = ctx.get("plugins");
  const report = (what: string) => (error: unknown) => ctx.notify("error", `${what}: ${String(error)}`);
  tui.commands.add({
    name: "open",
    description: "Show the plugins of config.json, and sync, update, add, or remove them",
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
    run: () => update(ctx, tui, plugins).catch(report("the update failed")),
  });
  return undefined;
}

/** The first seven digits of `commit`. */
function short(commit: string): string {
  return commit.slice(0, 7);
}

/** The sections of the dashboard, in order, with the test of the plugins of each one. */
const SECTIONS: readonly { readonly title: string; readonly has: (plugin: ManagedPlugin) => boolean }[] = [
  { title: "Needs sync", has: (plugin) => plugin.state === "not_locked" || plugin.state === "not_installed" },
  { title: "Installed", has: (plugin) => plugin.state === "installed" },
  { title: "Local", has: (plugin) => plugin.state === "local" },
];

/** The mark of `plugin`: loaded, not loaded, or a problem that a sync fixes. */
function markOf(plugin: ManagedPlugin): string {
  if (plugin.state === "not_locked" || plugin.state === "not_installed") return "!";
  return plugin.loaded ? "●" : "○";
}

/** The state of `plugin` after its source on its row. */
function stateOf(plugin: ManagedPlugin): string {
  switch (plugin.state) {
    case "local":
      return plugin.loaded ? "" : "not loaded";
    case "not_locked":
      return "not locked";
    case "not_installed":
      return `${short(plugin.commit)} not installed`;
    case "installed":
      return plugin.loaded ? short(plugin.commit) : `${short(plugin.commit)} not loaded`;
  }
}

/** The details of `plugin` under its row. */
function detailsOf(plugin: ManagedPlugin): string {
  const commit = "commit" in plugin ? ` · commit ${plugin.commit}` : "";
  return `${plugin.item}${commit} · ${plugin.loaded ? "loaded" : "not loaded"}`;
}

/** One row of the dashboard: a section title, a plugin, or the details of a plugin. */
type Row =
  | { readonly kind: "title"; readonly text: string }
  | { readonly kind: "plugin"; readonly plugin: ManagedPlugin }
  | { readonly kind: "details"; readonly plugin: ManagedPlugin };

/** The rows that each move key of the list moves the selection. */
const MOVES: Readonly<Record<string, number>> = { up: -1, k: -1, down: 1, j: 1 };

/**
 * The body of the dashboard: the plugins in their sections and a selection. Up, down, `j`, and `k` move the selection,
 * and Enter shows or hides the details of the selected plugin. The dialog takes each other key.
 */
class PluginList implements View {
  readonly focusable = true;
  #plugins: readonly ManagedPlugin[] = [];
  #selected = 0;
  readonly #open = new Set<string>();

  /** The plugins in section order. */
  get plugins(): readonly ManagedPlugin[] {
    return this.#plugins;
  }

  /** The selected plugin. */
  get selected(): ManagedPlugin | undefined {
    return this.#plugins[this.#selected];
  }

  /** Replace the plugins. The selection stays on the same item when the item is still there. */
  setPlugins(plugins: readonly ManagedPlugin[]): void {
    const kept = this.selected?.item;
    this.#plugins = SECTIONS.flatMap((section) => plugins.filter(section.has));
    this.select(kept);
  }

  /** Select the plugin of `item`, else keep the place in the list. */
  select(item: string | undefined): void {
    const index = this.#plugins.findIndex((plugin) => plugin.item === item);
    this.#selected = index >= 0 ? index : Math.min(this.#selected, Math.max(0, this.#plugins.length - 1));
  }

  #rows(): readonly Row[] {
    const rows: Row[] = [];
    for (const section of SECTIONS) {
      const plugins = this.#plugins.filter(section.has);
      if (plugins.length === 0) continue;
      rows.push({ kind: "title", text: `${section.title} (${plugins.length})` });
      for (const plugin of plugins) {
        rows.push({ kind: "plugin", plugin });
        if (this.#open.has(plugin.item)) rows.push({ kind: "details", plugin });
      }
    }
    return rows;
  }

  draw(canvas: Canvas): void {
    const rows = this.#rows();
    const selected = this.selected;
    if (rows.length === 0) canvas.text(1, 0, "config.json has no plugins: a adds one", DETAIL);
    const at = rows.findIndex((row) => row.kind === "plugin" && row.plugin === selected);
    const below = selected !== undefined && this.#open.has(selected.item) ? 1 : 0;
    // The view starts at the top, and it moves down only as far as the selection and its details need.
    const top = Math.max(0, Math.min(at, at + below - canvas.height + 1, rows.length - canvas.height));
    for (const [index, row] of rows.slice(top, top + canvas.height).entries()) {
      if (row.kind === "title") {
        canvas.text(1, index, row.text, TITLE);
      } else if (row.kind === "details") {
        canvas.text(6, index, detailsOf(row.plugin), DETAIL);
      } else {
        const plugin = row.plugin;
        const text = `${markOf(plugin)} ${(plugin.name ?? "?").padEnd(12)} ${plugin.item}  ${stateOf(plugin)}`;
        if (plugin === selected) canvas.fill(0, index, canvas.width, 1, SELECTED);
        canvas.text(2, index, text.trimEnd(), plugin === selected ? SELECTED : undefined);
      }
    }
  }

  key(event: KeyEvent): boolean {
    const stroke = strokeOf(event);
    const move = MOVES[stroke];
    if (move !== undefined) {
      this.#selected = Math.max(0, Math.min(this.#plugins.length - 1, this.#selected + move));
      return true;
    }
    const item = this.selected?.item;
    if (stroke !== "enter" || item === undefined) return false;
    if (!this.#open.delete(item)) this.#open.add(item);
    return true;
  }
}

/** The params of `plugins.add` of a line in the form of `yuke plugin add`: `URL [--folder FOLDER] [--ref REF]`. */
function addOf(line: string): AddPluginParams {
  const [git, ...rest] = line.trim().split(/\s+/);
  if (git === undefined || git === "" || git.startsWith("--")) throw new Error("give the URL of the repository first");
  const source: { git: string; folder?: string; ref?: string } = { git };
  for (let index = 0; index < rest.length; index += 2) {
    const flag = rest[index];
    const value = rest[index + 1];
    if (value === undefined || (flag !== "--folder" && flag !== "--ref")) {
      throw new Error(`'${flag ?? ""}' is not --folder FOLDER or --ref REF`);
    }
    if (flag === "--folder") source.folder = value;
    else source.ref = value;
  }
  return { source };
}

/** A text document of the one paragraph `text`. */
function paragraph(text: string): TextDocument {
  return { key: "paragraph", items: [{ key: "text", sections: [{ key: "text", kind: "text", text }] }] };
}

/** Open the dashboard. The title shows the count of the plugins and the state of the last action. */
async function open(ctx: PluginContext, tui: Tui, plugins: PluginManager): Promise<void> {
  const list = new PluginList();
  list.setPlugins((await plugins.list()).plugins);
  let status = "";
  let busy = false;
  const refresh = async (): Promise<void> => {
    list.setPlugins((await plugins.list()).plugins);
    tui.requestFrame();
  };
  /** Run `action` with `running` in the title, then show what it gives and load the list again. */
  const run = (running: string, action: () => Promise<string>): void => {
    busy = true;
    status = running;
    tui.requestFrame();
    action()
      .then(
        (done) => {
          status = done;
        },
        (error: unknown) => {
          status = `failed: ${String(error)}`;
        },
      )
      .then(refresh)
      .catch((error: unknown) => ctx.notify("error", `the plugins did not load: ${String(error)}`))
      .finally(() => {
        busy = false;
        tui.requestFrame();
      });
  };
  const idle = () => !busy;
  const named = () => {
    const name = list.selected?.name;
    return typeof name === "string" ? name : undefined;
  };
  const dialog = tui.dialog({
    title: () => `Plugins · ${list.plugins.length}${status === "" ? "" : ` · ${status}`}`,
    body: list,
    keys: [
      {
        key: "S",
        label: "sync",
        when: idle,
        run: () =>
          run("syncing", async () => {
            const synced = await plugins.sync({ signal: dialog.signal });
            return synced.written ? "plugins.lock written: R reloads" : "each Git plugin is at its locked commit";
          }),
      },
      { key: "U", label: "update all", when: idle, run: () => update("all") },
      {
        key: "u",
        label: "update",
        when: () => idle() && list.selected?.state === "installed" && named() !== undefined,
        run: () => update({ names: [named() ?? ""] }),
      },
      { key: "a", label: "add", when: idle, run: () => add() },
      { key: "d", label: "remove", when: () => idle() && named() !== undefined, run: () => remove(named() ?? "") },
      { key: "/", label: "search", when: () => idle() && list.plugins.length > 0, run: () => search() },
      { key: "R", label: "reload", when: idle, run: () => tui.commands.run("core:reload") },
    ],
  });
  /** Review the new commits of `target`, and write the chosen ones as an action of the dashboard. */
  const update = (target: PluginTarget): void => {
    review(tui, plugins, target, dialog.signal).then(
      (chosen) => {
        if (chosen === undefined) return;
        run("writing plugins.lock", async () =>
          (await plugins.apply(chosen)).written ? "plugins.lock written: R reloads" : "plugins.lock unchanged",
        );
      },
      (error: unknown) => {
        status = `the check failed: ${String(error)}`;
        tui.requestFrame();
      },
    );
  };
  const add = (): void => {
    let problem = "";
    const field = new TextEditor({
      multiline: false,
      placeholder: "URL [--folder FOLDER] [--ref REF]",
      submit: (state) => {
        let params: AddPluginParams;
        try {
          params = addOf(state.text);
        } catch (error) {
          // The prompt stays with its draft, so a fix needs no new typing.
          problem = String(error);
          tui.requestFrame();
          return;
        }
        prompt.close();
        run(`adding ${params.source.git}`, async () => {
          const added = await plugins.add(params, { signal: dialog.signal });
          return `${added.name} added at ${short(added.commit)}: R reloads`;
        });
      },
    });
    const prompt = tui.dialog({
      title: () => (problem === "" ? "Add a Git plugin" : problem),
      body: field,
      rows: 3,
      signal: dialog.signal,
    });
  };
  const remove = (name: string): void => {
    const question = new TextView({ document: paragraph(`Remove ${name} from config.json and plugins.lock?`) });
    const confirm = tui.dialog({
      body: question,
      rows: 3,
      signal: dialog.signal,
      keys: [
        {
          key: "enter",
          label: "remove",
          run: () => {
            confirm.close();
            run(`removing ${name}`, async () => {
              await plugins.remove(name);
              return `${name} removed: R reloads`;
            });
          },
        },
      ],
    });
  };
  const search = (): void => {
    const picker = new Picker<ManagedPlugin>({
      items: list.plugins,
      key: (plugin) => plugin.item,
      label: (plugin) => `${plugin.name ?? "?"}  ${plugin.item}`,
      choose: (plugin) => {
        list.select(plugin.item);
        found.close();
      },
      cancel: () => found.close(),
    });
    const found = tui.dialog({ title: () => "Search the plugins", body: picker, signal: dialog.signal });
  };
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

/** Check each Git plugin in a review, and write the new commits that the user chooses. Notices tell the result. */
async function update(ctx: PluginContext, tui: Tui, plugins: PluginManager): Promise<void> {
  const chosen = await review(tui, plugins, "all", ctx.signal);
  if (chosen === undefined) return;
  const applied = await plugins.apply(chosen);
  ctx.notify(
    "info",
    applied.written ? "plugins.lock written: run /reload to load the new commits" : "plugins.lock unchanged",
  );
}

/**
 * Check the Git plugins of `target` in a dialog that closes when `signal` aborts. The dialog opens at once, and its close
 * (Esc) stops the check. Gives the changes when the user presses Enter on them, else `undefined` at the close.
 */
async function review(
  tui: Tui,
  plugins: PluginManager,
  target: PluginTarget,
  signal: AbortSignal,
): Promise<readonly PluginChange[] | undefined> {
  let changes: readonly PluginChange[] = [];
  let chosen: readonly PluginChange[] | undefined;
  const text = new TextView({ document: documentOf([{ label: "the check of the Git plugins runs", lines: [] }]) });
  const dialog = tui.dialog({
    body: text,
    signal,
    keys: [
      {
        key: "enter",
        label: "write plugins.lock",
        when: () => changes.length > 0,
        run: () => {
          chosen = changes;
          dialog.close();
        },
      },
    ],
  });
  const closed = new Promise<void>((resolve) =>
    dialog.signal.addEventListener("abort", () => resolve(), { once: true }),
  );
  try {
    changes = (await plugins.check(target, { signal: dialog.signal })).changes;
  } catch (error) {
    // A close of the dialog stops the check, and the user saw it close.
    if (dialog.signal.aborted) return undefined;
    dialog.close();
    throw error;
  }
  text.setDocument(
    changes.length === 0
      ? documentOf([{ label: "each Git plugin is at the newest commit of its ref", lines: [] }])
      : reviewOf(changes),
  );
  tui.requestFrame();
  await closed;
  return chosen;
}
