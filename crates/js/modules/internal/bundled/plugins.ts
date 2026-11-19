/**
 * The bundled plugin `plugins`. Its command `plugins:open` shows the plugins of `config.json` in three sections: the
 * plugins that need attention, the Git plugins, and the local plugins. Its keys sync, check for updates, update, add,
 * remove, and reload. A check shows the new commits before it writes them, and each change loads at the next reload.
 */

import { plugins as manager, type PluginManager } from "yuke:internal/sessions";
import type { PluginContext } from "yuke:plugins";
import type { FoundPlugin, ManagedPlugin, PluginChange, PluginTarget } from "yuke:protocol";
import {
  type Canvas,
  type KeyEvent,
  type Placement,
  ScrollList,
  type Size,
  SPINNER_INTERVAL,
  spinner,
  strokeOf,
  type TextDocument,
  type TextRow,
  TextView,
  type Tui,
  type View,
  wrap,
} from "yuke:tui";

const TITLE = "plugins.title";
const DETAIL = "picker.detail";
const ERROR = "dialog.error";
const SELECTED = "picker.selected";

/** A test gives a fake manager as `plugins`. */
export function apply(ctx: PluginContext, plugins: PluginManager = manager): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  tui.commands.add({
    name: "open",
    slash: "plugins",
    description: "Show your plugins, and sync, update, add, or remove them",
    run: () =>
      open(ctx, tui, plugins).catch((error: unknown) =>
        ctx.notify("error", `The plugins did not load: ${messageOf(error)}`),
      ),
  });
  return undefined;
}

/** The text of `error` without the name of its class. */
function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** The first seven digits of `commit`. */
function short(commit: string): string {
  return commit.slice(0, 7);
}

/** The name of `plugin`, else the last part of its folder or of its URL. */
function nameOf(plugin: ManagedPlugin): string {
  if (plugin.name !== undefined) return plugin.name;
  const source = plugin.source;
  const text = (typeof source === "string" ? source : (source.folder ?? source.git)).replace(/\/+$/, "");
  return (text.split(/[/:]/).at(-1) ?? text).replace(/\.git$/, "");
}

/** The source of `plugin` on its row: the folder, or the Git URL without `https://`, with its folder and ref. */
function sourceOf(plugin: ManagedPlugin): string {
  const source = plugin.source;
  if (typeof source === "string") return source;
  const parts = [
    source.git.replace(/^https:\/\//, ""),
    source.folder,
    source.ref === undefined ? undefined : `ref ${source.ref}`,
  ];
  return parts.filter((part) => part !== undefined).join(" · ");
}

/** The key of `plugin` in the list. */
function keyOf(plugin: ManagedPlugin): string {
  return JSON.stringify(plugin.source);
}

/** The titles of the sections of the dashboard, in order. */
const SECTIONS = ["Needs attention", "Git", "Local"] as const;

/** The index in `SECTIONS` of the section of `plugin`: a plugin that is not installed or does not load needs attention. */
function sectionOf(plugin: ManagedPlugin): number {
  if (plugin.state.kind === "notInstalled" || plugin.load.kind === "failed") return 0;
  return plugin.state.kind === "installed" ? 1 : 2;
}

/** The mark and the state word of each load of a plugin that is installed. */
const LOADS = {
  loaded: { mark: "●", state: "loaded" },
  pending: { mark: "○", state: "reload loads it" },
  failed: { mark: "✗", state: "failed" },
} as const;

/** The width of the state column: the longest state word. */
const STATE_WIDTH = "reload loads it".length;

/** The mark and the state word of `plugin`. */
function statusOf(plugin: ManagedPlugin): { readonly mark: string; readonly state: string } {
  return plugin.state.kind === "notInstalled" ? { mark: "!", state: "not installed" } : LOADS[plugin.load.kind];
}

/** Why `plugin` needs attention, with the look of the text, or `undefined` when it does not. */
function reasonOf(plugin: ManagedPlugin): { readonly text: string; readonly style: string } | undefined {
  if (plugin.state.kind === "notInstalled") return { text: "s installs it", style: DETAIL };
  return plugin.load.kind === "failed" ? { text: plugin.load.error, style: ERROR } : undefined;
}

/** One row of the dashboard: a section title, a plugin, or the reason of a plugin that needs attention. */
type Row =
  | { readonly kind: "title"; readonly text: string }
  | { readonly kind: "plugin"; readonly plugin: ManagedPlugin; readonly nameWidth: number; readonly selected: boolean }
  | { readonly kind: "reason"; readonly plugin: ManagedPlugin; readonly text: string; readonly style: string };

/** The id of `row` in the list. */
function idOf(row: Row): string {
  return row.kind === "title" ? `title ${row.text}` : `${row.kind} ${keyOf(row.plugin)}`;
}

/** The text rows of `row` at `width` cells. A reason wraps below its plugin. */
function render(row: Row, width: number): readonly TextRow[] {
  if (row.kind === "title") return [{ segments: [{ text: ` ${row.text}`, style: TITLE }], join: "\n" }];
  if (row.kind === "reason") {
    const indent = "      ";
    return wrap(row.text, Math.max(1, width - indent.length)).map((part) => ({
      segments: [{ text: `${indent}${row.text.slice(part.start, part.end)}`, style: row.style }],
      join: "\n",
    }));
  }
  const plugin = row.plugin;
  const status = statusOf(plugin);
  const commit = plugin.state.kind === "installed" ? short(plugin.state.commit) : "";
  const text = `  ${status.mark} ${nameOf(plugin).padEnd(row.nameWidth)}  ${status.state.padEnd(STATE_WIDTH)}  ${commit.padEnd(7)}  ${sourceOf(plugin)}`;
  // The band of the selected row reaches the last column.
  return [
    {
      segments: [{ text: row.selected ? text.padEnd(width) : text, style: row.selected ? SELECTED : undefined }],
      join: "\n",
    },
  ];
}

/** The rows that each move key of the list moves the selection. */
const MOVES: Readonly<Record<string, number>> = { up: -1, k: -1, down: 1, j: 1 };

/** The body of the dashboard: the plugins in their sections and a selection. Up, down, `j`, and `k` move it. */
class PluginList implements View {
  readonly focusable = true;
  readonly #list = new ScrollList<Row>({ id: idOf, render });
  /** The plugins of each section, in the order of `SECTIONS`. */
  #sections: readonly (readonly ManagedPlugin[])[] = [];
  #selected = 0;
  /** The selection moved, so the next layout shows it. */
  #reveal = true;

  /** The plugins in section order. */
  get plugins(): readonly ManagedPlugin[] {
    return this.#sections.flat();
  }

  /** The selected plugin. */
  get selected(): ManagedPlugin | undefined {
    return this.plugins[this.#selected];
  }

  /** The count of the rows of the list. */
  get rowCount(): number {
    return this.#list.items.length;
  }

  /** Replace the plugins. The selection stays on the same plugin when it is still there, else on its place. */
  setPlugins(plugins: readonly ManagedPlugin[]): void {
    const kept = this.selected === undefined ? undefined : keyOf(this.selected);
    this.#sections = SECTIONS.map((_, index) => plugins.filter((plugin) => sectionOf(plugin) === index));
    const index = this.plugins.findIndex((plugin) => keyOf(plugin) === kept);
    this.#select(index >= 0 ? index : this.#selected);
  }

  #select(index: number): void {
    const plugins = this.plugins;
    this.#selected = Math.max(0, Math.min(plugins.length - 1, index));
    const nameWidth = Math.max(0, ...plugins.map((plugin) => nameOf(plugin).length));
    const selected = this.selected;
    const rows: Row[] = [];
    for (const [index, section] of this.#sections.entries()) {
      if (section.length > 0) rows.push({ kind: "title", text: `${SECTIONS[index]} (${section.length})` });
      for (const plugin of section) {
        rows.push({ kind: "plugin", plugin, nameWidth, selected: plugin === selected });
        const reason = reasonOf(plugin);
        if (reason !== undefined) rows.push({ kind: "reason", plugin, ...reason });
      }
    }
    this.#list.setItems(rows);
    this.#reveal = true;
  }

  layout(size: Size): readonly Placement[] {
    this.#list.layout(size);
    const selected = this.selected;
    if (this.#reveal && selected !== undefined) {
      // The reason below the selected plugin shows when it fits, and the plugin row shows always.
      this.#list.ensureVisible(`reason ${keyOf(selected)}`);
      this.#list.ensureVisible(`plugin ${keyOf(selected)}`);
    }
    this.#reveal = false;
    return [{ view: this.#list, rect: { column: 0, row: 0, width: size.width, height: size.height } }];
  }

  draw(canvas: Canvas): void {
    if (this.plugins.length === 0) canvas.text(1, 0, "config.json has no plugins · a adds one", DETAIL);
  }

  onKey(event: KeyEvent): boolean {
    const move = MOVES[strokeOf(event)];
    if (move === undefined) return false;
    this.#select(this.#selected + move);
    return true;
  }
}

/** A spinner that draws a frame of `tui` at each step until `stop`. */
function startSpinner(tui: Tui): { readonly frame: () => string; readonly stop: () => void } {
  const start = tui.now();
  const tick = (): void => {
    cancel = tui.addTimer(SPINNER_INTERVAL, tick);
  };
  let cancel = tui.addTimer(SPINNER_INTERVAL, tick);
  return { frame: () => spinner(tui.now() - start), stop: () => cancel() };
}

/** The plugins of `changes` for a sentence: the name of one, else their count. */
function namesOf(changes: readonly PluginChange[]): string {
  return changes.length === 1 ? (changes[0] as PluginChange).name : `${changes.length} plugins`;
}

/** Open the dashboard. The title shows the count of the plugins and the state of the last action. */
async function open(ctx: PluginContext, tui: Tui, plugins: PluginManager): Promise<void> {
  const list = new PluginList();
  list.setPlugins((await plugins.list()).plugins);
  let status = "";
  let running: ReturnType<typeof startSpinner> | undefined;
  /**
   * Run `action` with `doing` and a spinner in the title. Then show the text that it gives, or give a notice of its
   * failure, and load the list again.
   */
  const run = async (doing: string, action: () => Promise<string>): Promise<void> => {
    const spin = startSpinner(tui);
    running = spin;
    status = doing;
    tui.requestFrame();
    try {
      status = await action();
    } catch (error) {
      status = "";
      const label = `${doing.charAt(0).toUpperCase()}${doing.slice(1)}`;
      if (!dialog.signal.aborted) ctx.notify("error", `${label} failed: ${messageOf(error)}`);
    }
    try {
      list.setPlugins((await plugins.list()).plugins);
    } catch (error) {
      ctx.notify("error", `The plugins did not load: ${messageOf(error)}`);
    } finally {
      spin.stop();
      running = undefined;
      tui.requestFrame();
    }
  };
  const idle = () => running === undefined;
  const named = () => list.selected?.name;
  const dialog = tui.dialog({
    title: () => {
      const doing = running === undefined ? status : `${running.frame()} ${status}…`;
      return `Plugins · ${list.plugins.length}${doing === "" ? "" : ` · ${doing}`}`;
    },
    body: list,
    // The dialog shows each plugin when the screen has the rows: the list, the head row, and the footer.
    rows: Math.max(13, list.rowCount + 2),
    keys: [
      { key: "s", label: "sync", when: idle, run: () => sync() },
      { key: "c", label: "check updates", when: idle, run: () => update({ kind: "all" }) },
      {
        key: "u",
        label: "update",
        when: () => idle() && list.selected?.state.kind === "installed" && named() !== undefined,
        run: () => update({ kind: "names", names: [named() ?? ""] }),
      },
      { key: "a", label: "add", when: idle, run: () => void add() },
      { key: "d", label: "remove", when: () => idle() && named() !== undefined, run: () => void remove(named() ?? "") },
      { key: "r", label: "reload", when: idle, run: () => tui.commands.run("core:reload") },
    ],
  });
  const sync = (): void => {
    const missing = list.plugins.filter((plugin) => plugin.state.kind === "notInstalled");
    void run("syncing", async () => {
      await plugins.sync({ signal: dialog.signal });
      const [first] = missing;
      if (first === undefined) return "each Git plugin is installed";
      return missing.length === 1
        ? `installed ${nameOf(first)} · r loads it`
        : `installed ${missing.length} plugins · r loads them`;
    });
  };
  /** Check the plugins of `target` in a review, and write the commits that the user chooses. */
  const update = (target: PluginTarget): void => {
    review(tui, plugins, target, dialog.signal).then(
      (chosen) => {
        if (chosen === undefined) return;
        void run("updating", async () => {
          await plugins.apply(chosen.map((change) => ({ source: change.source, commit: change.new })));
          return `updated ${namesOf(chosen)} · r loads the new commits`;
        });
      },
      (error: unknown) => ctx.notify("error", `The check failed: ${messageOf(error)}`),
    );
  };
  const add = async (): Promise<void> => {
    let found: readonly FoundPlugin[] = [];
    // A URL that gives no new plugin keeps the prompt open with its text and the reason.
    const line = await tui.input({
      title: "Add a plugin",
      placeholder: "URL of a Git repository",
      signal: dialog.signal,
      onSubmit: async (text) => {
        const git = text.trim();
        if (git === "") throw new Error("type the URL of a Git repository");
        const added = new Set(list.plugins.map(nameOf));
        const all = (await plugins.find({ git }, { signal: dialog.signal })).plugins;
        found = all.filter((plugin) => !added.has(plugin.name));
        if (all.length === 0) throw new Error("the repository has no plugin.json");
        if (found.length === 0) throw new Error("config.json has each plugin of the repository already");
      },
    });
    if (line === undefined) return;
    const git = line.trim();
    const chosen =
      found.length === 1
        ? found[0]
        : await tui.select({
            title: `Add a plugin · ${git.replace(/^https:\/\//, "")}`,
            items: found,
            label: (plugin) => plugin.name,
            detail: (plugin) => plugin.folder ?? "the root of the repository",
            signal: dialog.signal,
          });
    if (chosen === undefined) return;
    void run(`adding ${chosen.name}`, async () => {
      await plugins.add({ git, names: [chosen.name] }, { signal: dialog.signal });
      return `added ${chosen.name} · r loads it`;
    });
  };
  const remove = async (name: string): Promise<void> => {
    const git = typeof list.selected?.source === "object";
    const confirmed = await tui.confirm({
      title: `Remove ${name}?`,
      text: `yuke removes ${name} from config.json${git ? " and plugins.lock" : ""}. Its files stay on disk, and it runs until the next reload.`,
      confirmLabel: "remove",
      cancelLabel: "keep",
      signal: dialog.signal,
    });
    if (!confirmed) return;
    void run(`removing ${name}`, async () => {
      await plugins.remove(name);
      return `removed ${name} · r unloads it`;
    });
  };
}

/** The review of `changes`: each plugin with its move and the log of the move, or one line without a change. */
function reviewOf(changes: readonly PluginChange[] | undefined): TextDocument {
  const items: readonly { readonly label: string; readonly log?: string }[] =
    changes === undefined
      ? [{ label: "Checking each Git plugin for a new commit" }]
      : changes.length === 0
        ? [{ label: "Each Git plugin is at the newest commit of its ref" }]
        : changes.map((change) => ({
            label: `${change.name}  ${short(change.old)} → ${short(change.new)}`,
            log:
              change.log.kind === "commits"
                ? change.log.commits.map((line) => `  ${line}`).join("\n")
                : `  no log: ${change.log.error}`,
          }));
  return {
    id: "plugins-review",
    items: items.map((item, index) => ({
      id: String(index),
      sections: [
        { id: "label", kind: "label", text: item.label },
        ...(item.log ? [{ id: "log", kind: "text" as const, text: item.log }] : []),
      ],
    })),
  };
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
  let changes: readonly PluginChange[] | undefined;
  let chosen: readonly PluginChange[] | undefined;
  const text = new TextView({ document: reviewOf(undefined) });
  const checking = startSpinner(tui);
  const dialog = tui.dialog({
    title: () => (changes === undefined ? `Updates · ${checking.frame()} checking…` : `Updates · ${namesOf(changes)}`),
    body: text,
    scroll: text.scroll,
    signal,
    keys: [
      {
        key: "enter",
        label: "update",
        when: () => changes !== undefined && changes.length > 0,
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
  } finally {
    checking.stop();
  }
  text.setDocument(reviewOf(changes));
  tui.requestFrame();
  await closed;
  return chosen;
}
