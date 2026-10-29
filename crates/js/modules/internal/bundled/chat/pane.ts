/**
 * One chat pane: its transcript, its composer, its folds, and the handle of its session. An unbound pane creates its
 * session at the first send. The model and the reasoning come from `tui.startup`, else from a picker.
 */

import { blocksOf, draftOf, EMPTY, joined, PASTE_SPAN } from "yuke:internal/bundled/chat/composer";
import { STYLE } from "yuke:internal/bundled/chat/rows";
import { ChatDocument } from "yuke:internal/bundled/chat/transcript";
import type { EventsPage, PluginContext, SessionHandle, ViewEvent } from "yuke:plugins";
import type { ModelInfo, ProviderInfo, SessionId, SessionSettings } from "yuke:protocol";
import { type Entry, Transcript } from "yuke:transcript";
import {
  type Canvas,
  type EditorState,
  type JsonValue,
  type Mount,
  Picker,
  type Placement,
  type Size,
  type Startup,
  strokeOf,
  TextEditor,
  TextView,
  type Tui,
  type View,
} from "yuke:tui";

const RULE = Object.freeze({ dim: true });

/** The count of saved events that a pane gets when it opens its session. Older events come in pages. */
const TAIL = 200;

/** The most saved events of one page of history. */
const PAGE = 100;

/** The most rows of a picker of a pane. */
const PICKER_ROWS = 12;

/** The item at the top of a scrolled transcript, and its row there. */
interface Viewport {
  readonly key: string;
  readonly row: number;
}

/**
 * The saved state of a pane: the session that it shows, the draft of its composer, its fold choices, and the place of
 * a transcript that does not follow the tail.
 */
export interface PaneState {
  readonly session?: SessionId | undefined;
  readonly draft?: EditorState | undefined;
  readonly folds?: readonly (readonly [string, boolean])[] | undefined;
  readonly viewport?: Viewport | undefined;
}

/** What the commands of the plugin do in a pane. */
export interface PaneActions {
  readonly toggleTools: () => void;
  readonly send: () => void;
  /** Let the user choose the model and the reasoning of the pane. */
  readonly chooseModel: () => void;
  /** Show an older (-1) or a newer (1) message of the user in the composer, or the draft after the newest one. */
  readonly browse: (step: -1 | 1) => void;
  /** An empty composer or a browse can show an older message. */
  readonly canBrowse: () => boolean;
  readonly browsing: () => boolean;
  /** Clear the draft. An empty draft cancels the running turn. */
  readonly clear: () => void;
  /** Drop the selection of the transcript, else cancel the running turn. */
  readonly interrupt: () => void;
  readonly scroll: (to: "pageUp" | "pageDown" | "top" | "bottom") => void;
  /** Move the focus between the composer and the transcript. */
  readonly switchFocus: () => void;
  /** Act on the caret of the transcript, as a click does. */
  readonly activate: () => void;
  /** Copy the selection of the transcript. */
  readonly copy: () => void;
}

/** What each pane of the chat shares. */
export interface Chat {
  readonly ctx: PluginContext<{ readonly copyOnRelease?: boolean | undefined }>;
  readonly tui: Tui;
  readonly copyOnRelease: boolean;
  /** The actions of each pane, by its view. */
  readonly panes: WeakMap<View, PaneActions>;
}

/** Check the session, the folds, and the viewport of a saved `state`. A bad field throws a `TypeError`. */
export function paneState(state: unknown): PaneState {
  if (typeof state !== "object" || state === null) throw new TypeError("the state of a chat pane is an object");
  const saved = state as { readonly session?: unknown; readonly folds?: unknown; readonly viewport?: unknown };
  if (saved.session !== undefined && typeof saved.session !== "string") {
    throw new TypeError("the session of a chat pane is a session id");
  }
  const folds = saved.folds ?? [];
  const fold = (pair: unknown): boolean =>
    Array.isArray(pair) && pair.length === 2 && typeof pair[0] === "string" && typeof pair[1] === "boolean";
  if (!Array.isArray(folds) || !folds.every(fold)) {
    throw new TypeError("the folds of a chat pane are [key, open] pairs");
  }
  const viewport = saved.viewport as Partial<Viewport> | undefined;
  const row = viewport?.row;
  if (viewport !== undefined && (typeof viewport.key !== "string" || !Number.isInteger(row) || (row as number) < 0)) {
    throw new TypeError("the viewport of a chat pane has a key and a row");
  }
  // The editor checks the draft.
  return state as PaneState;
}

/**
 * A chat pane: the transcript above a rule and the composer. The composer takes at most half the pane height. A pane
 * with a session holds its own handle until the mount closes.
 */
export function chatPane(chat: Chat, mount: Mount, state: PaneState): View {
  const ctx = chat.ctx;
  const tui = chat.tui;
  const sessions = ctx.get("sessions");
  let session = state.session;
  let handle: SessionHandle | undefined;
  // The open of the session, so a send waits for it.
  let opening: Promise<SessionHandle | undefined> | undefined;
  const transcript = new Transcript();
  let document = new ChatDocument(`session:${session ?? "new"}`, state.folds);
  // The events of the session change the transcript, and the next layout projects it once.
  let dirty = true;
  // The first snapshot came, so a page can load.
  let opened = false;
  let loading = false;
  // The oldest saved event is in the transcript.
  let complete = false;
  let historyError: string | undefined;
  // The saved place waits until its item loads.
  let restore = state.viewport;
  // One send or model choice at a time: the next Enter waits until the session accepts or refuses the input, also
  // while a picker is open.
  let busy = false;
  // The settings that the user chose for the first send of an unbound pane.
  let chosen: SessionSettings | undefined;
  // The draft before a browse of the messages, and the key of the shown message.
  let browse: { readonly draft: EditorState; readonly key: string } | undefined;
  const changed = (): void => {
    dirty = true;
    tui.requestFrame();
  };

  /** Load one page: the newest part of a gap first, else the page before the first held event. */
  const load = async (): Promise<void> => {
    if (session === undefined || !opened || loading || historyError !== undefined) return;
    const id = session;
    const gap = transcript.gap;
    const first = transcript.first;
    let page: EventsPage;
    if (gap !== undefined) page = { ...gap, limit: Math.min(PAGE, gap.limit) };
    else if (complete || first === undefined) return;
    else page = { before: first, limit: PAGE };
    loading = true;
    try {
      const events = await sessions.events(id, page);
      if (mount.signal.aborted) return;
      transcript.insert(events);
      // A page that adds nothing older ends the history, so a load never repeats it.
      if (gap === undefined && transcript.first === first) complete = true;
    } catch (error) {
      if (mount.signal.aborted) return;
      historyError = `the history did not load: ${String(error)}`;
    } finally {
      loading = false;
    }
    changed();
  };

  const event = (update: ViewEvent): void => {
    transcript.apply(update);
    if ("snapshot" in update) opened = true;
    changed();
    if (transcript.gap !== undefined) void load();
  };

  /**
   * Open the session `id` for this pane. A failure before the close of the pane gives one notice and no handle. The
   * next send then opens the session again.
   */
  const open = (id: SessionId): Promise<SessionHandle | undefined> =>
    sessions.open(id, { tail: TAIL, signal: mount.signal, event }).then(
      (opened) => {
        handle = opened;
        return opened;
      },
      (error: unknown) => {
        opening = undefined;
        if (!mount.signal.aborted) ctx.notify("error", `the session ${id} did not open: ${String(error)}`);
        return undefined;
      },
    );
  if (session !== undefined) opening = open(session);

  const group = {};
  const view = new TextView({
    document: document.project(transcript),
    role: "transcript",
    group,
    copyOnRelease: chat.copyOnRelease,
    followTail: true,
    activate: (position, link) => {
      if (link === undefined) {
        if (position.section === "title" && document.toggle(transcript, position.item)) changed();
        return;
      }
      // A relative target starts in the folder of its tool call, else in the folder of the session, else at the start.
      const entry = transcript.entries.find((candidate) => candidate.key === position.item);
      const folder = (entry?.kind === "tool" ? entry.folder : undefined) ?? transcript.settings?.cwd ?? tui.startup.cwd;
      const absolute = /^[a-z][a-z0-9+.-]*:/i.test(link) || link.startsWith("/");
      const target = absolute ? link : `${folder.replace(/\/$/, "")}/${link}`;
      tui.copy(target);
      ctx.notify("info", `copied ${target}`);
    },
    requestOlder: load,
  });
  const composer = new TextEditor({
    role: "composer",
    group,
    placeholder: "Message…",
    ...(state.draft === undefined ? {} : { state: state.draft }),
  });
  const extension = composer.extend(mount.signal);
  // A long paste shows a label, and the draft keeps its whole text for the input.
  extension.onPaste((text) => {
    if (text.length <= PASTE_SPAN) return false;
    const selection = composer.selection;
    composer.replace(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head), text, [
      { from: 0, to: text.length, kind: "paste", label: `[Pasted text · ${text.length} chars]` },
    ]);
    return true;
  });
  // A slash in an empty composer opens the palette. Esc gives the slash back, so a message can start with one.
  extension.onKey((event) => {
    if (strokeOf(event) !== "/" || composer.state.text !== "") return false;
    const palette = tui.palette({ cancel: () => composer.replace(0, 0, "/") });
    const close = (): void => palette.close();
    mount.signal.addEventListener("abort", close, { once: true });
    palette.signal.addEventListener("abort", () => mount.signal.removeEventListener("abort", close), { once: true });
    return true;
  });
  // An edit of the shown message ends the browse, so the edited text stays.
  extension.onChange((change) => {
    if (change.kind === "edit") browse = undefined;
  });

  /**
   * Let the user choose one of `items` in a picker above the composer. Return `undefined` when no item is chosen. The
   * close of the pane closes the picker.
   */
  const choose = <T extends object>(items: readonly T[], label: (item: T) => string): Promise<T | undefined> =>
    new Promise((resolve) => {
      if (mount.signal.aborted) {
        resolve(undefined);
        return;
      }
      let picked: T | undefined;
      const overlay = tui.overlay(
        () =>
          new Picker<T>({
            items,
            key: label,
            label,
            choose: (item) => {
              picked = item;
              overlay.close();
            },
            cancel: () => overlay.close(),
          }),
        {
          place: (size) => {
            const height = Math.min(PICKER_ROWS, size.height);
            return { column: 0, row: size.height - height, width: size.width, height };
          },
        },
      );
      const close = (): void => overlay.close();
      mount.signal.addEventListener("abort", close, { once: true });
      overlay.signal.addEventListener("abort", () => {
        mount.signal.removeEventListener("abort", close);
        resolve(picked);
      });
    });

  /**
   * The settings of a new session in the folder of `startup`. The model and the level come from `startup` when it names
   * them, else the user chooses them. The picker shows only explicit levels, so `default` is never a choice. A cancel
   * and a model that is not ready give `undefined`.
   */
  const settingsOf = async (startup: Startup): Promise<SessionSettings | undefined> => {
    const providers = (await ctx.get("catalog").list()).providers;
    const models = providers.flatMap((provider: ProviderInfo) =>
      provider.models.map((model: ModelInfo) => ({ provider: provider.id, model })),
    );
    const wanted = startup.model;
    const chosen =
      wanted === undefined
        ? await choose(models, (entry) => `${entry.provider}/${entry.model.id}`)
        : models.find((entry) => entry.provider === wanted.provider && entry.model.id === wanted.model);
    if (chosen === undefined) {
      if (wanted !== undefined) ctx.notify("error", `the model ${wanted.provider}/${wanted.model} is not ready`);
      return undefined;
    }
    const levels = chosen.model.reasoning.filter((choice) => choice.level !== "default");
    const reasoning =
      startup.reasoning === undefined
        ? await choose(levels, (choice) => choice.level)
        : levels.find((choice) => choice.level === startup.reasoning);
    if (reasoning === undefined) {
      if (startup.reasoning !== undefined) {
        ctx.notify("error", `the model ${chosen.provider}/${chosen.model.id} does not take ${startup.reasoning}`);
      }
      return undefined;
    }
    return {
      model: { provider: chosen.provider, model: chosen.model.id },
      settings: {
        maxOutputTokens: null,
        reasoning: reasoning.settings,
        temperature: null,
        topP: null,
        toolChoice: "auto",
        outputSchema: null,
      },
      cwd: startup.cwd,
    };
  };

  /**
   * Let the user choose the model and the level. An unbound pane keeps them for its first send. A pane with a session
   * saves them in the session. The session keeps its folder and the rest of its settings.
   */
  const chooseModel = async (): Promise<void> => {
    if (busy) return;
    busy = true;
    try {
      // The user chooses both, also when the startup names them.
      const settings = await settingsOf({ cwd: tui.startup.cwd });
      if (settings === undefined || mount.signal.aborted) return;
      if (session === undefined) {
        chosen = settings;
        return;
      }
      opening ??= open(session);
      const target = handle ?? (await opening);
      const current = transcript.settings;
      if (target === undefined || current === undefined) throw new Error(`the session ${session} is not open`);
      const reasoning = settings.settings.reasoning;
      await target.setSettings({ ...current, model: settings.model, settings: { ...current.settings, reasoning } });
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the model did not change: ${String(error)}`);
    } finally {
      busy = false;
    }
  };

  /**
   * Send the draft. An unbound pane gets its settings first, and a cancel keeps the draft. Then the composer clears,
   * so the user can type the next message. A pane without a session creates it. A refused input comes back above the
   * newer text.
   */
  const send = async (): Promise<void> => {
    if (busy) return;
    const draft = composer.state;
    const blocks = blocksOf(draft);
    if (blocks.length === 0) return;
    busy = true;
    try {
      let settings: SessionSettings | undefined;
      if (session === undefined) {
        try {
          settings = chosen ?? (await settingsOf(tui.startup));
        } catch (error) {
          if (!mount.signal.aborted) ctx.notify("error", `the models did not load: ${String(error)}`);
          return;
        }
        if (settings === undefined || mount.signal.aborted) return;
      }
      composer.reset(EMPTY);
      browse = undefined;
      try {
        if (settings !== undefined) {
          const id = await sessions.create(settings);
          if (mount.signal.aborted) return;
          session = id;
          document = new ChatDocument(`session:${id}`, document.folds);
          opening = open(id);
          changed();
        }
        // A failed open of a bound pane opens again here.
        opening ??= session === undefined ? undefined : open(session);
        const target = handle ?? (await opening);
        if (target === undefined) throw new Error(`the session ${session} is not open`);
        await target.input(blocks);
      } catch (error) {
        if (mount.signal.aborted) return;
        browse = undefined;
        composer.reset(joined(draft, composer.state));
        ctx.notify("error", `the message did not send: ${String(error)}`);
      }
    } finally {
      busy = false;
    }
  };

  // The layout keeps the row of the rule for the draw. Without a free row, the pane draws no rule.
  let ruleRow = -1;
  const pane: View = {
    contexts: ["chat"],
    layout(size: Size): readonly Placement[] {
      if (dirty) {
        dirty = false;
        view.setDocument(document.project(transcript));
      }
      // The composer keeps one row in a pane of any size, and at most half of a taller pane.
      const composerRows = Math.min(composer.heightFor(size.width), Math.max(1, Math.floor(size.height / 2)));
      const composerRow = Math.max(0, size.height - composerRows);
      ruleRow = composerRow - 1;
      const placements = [
        { view, rect: { column: 0, row: 0, width: size.width, height: Math.max(0, ruleRow) } },
        { view: composer, rect: { column: 0, row: composerRow, width: size.width, height: size.height - composerRow } },
      ];
      // The view has rows only after its own first layout. The saved place waits for a height, then for its item or
      // the end of the history.
      if (restore !== undefined && opened && view.scroll.state.height > 0) {
        const key = restore.key;
        if (view.document.items.some((item) => item.key === key)) {
          // A row past the end of a changed item gives its first row.
          if (!view.scroll.scrollToItem(key, restore.row)) view.scroll.scrollToItem(key);
          restore = undefined;
        } else if (complete || historyError !== undefined) restore = undefined;
        else void load();
      }
      return placements;
    },
    draw(canvas: Canvas): void {
      if (ruleRow < 0) return;
      canvas.text(0, ruleRow, "─".repeat(canvas.width), RULE);
      // The rule shows a failed history load, so the text stays in sight at any scroll place.
      if (historyError !== undefined) canvas.text(1, ruleRow, ` ${historyError} `, STYLE.error);
      else if (view.scroll.state.changedBelow) canvas.text(1, ruleRow, " new output ↓ ", STYLE.hint);
    },
    initialFocus: composer,
    snapshot: () => {
      const scroll = view.scroll.state;
      const viewport = restore ?? (scroll.following ? undefined : scroll.anchor);
      return {
        type: "pane",
        state: {
          ...(session === undefined ? {} : { session }),
          draft: composer.state as unknown as JsonValue,
          folds: document.folds,
          ...(viewport === undefined ? {} : { viewport: { key: viewport.key, row: viewport.row } }),
        },
      };
    },
  };
  chat.panes.set(pane, {
    toggleTools: () => {
      document.toggleTools(transcript);
      changed();
    },
    send: () => void send(),
    chooseModel: () => void chooseModel(),
    browsing: () => browse !== undefined,
    canBrowse: () => browse !== undefined || composer.state.text === "",
    browse: (step) => {
      // The messages of the user in the transcript, oldest first.
      const list = transcript.entries.filter(
        (entry): entry is Extract<Entry, { kind: "input" }> =>
          entry.kind === "input" && entry.source.kind === "user" && entry.inputKind === "message",
      );
      const at = browse === undefined ? list.length : list.findIndex((entry) => entry.key === browse?.key);
      const next = list[at + step];
      if (next === undefined) {
        if (step === 1 && browse !== undefined) {
          composer.reset(browse.draft);
          browse = undefined;
        } else if (step === -1) void load();
        return;
      }
      browse = { draft: browse?.draft ?? composer.state, key: next.key };
      composer.reset(draftOf(next.content));
    },
    clear: () => {
      if (composer.state.text === "") handle?.cancel();
      else {
        composer.reset(EMPTY);
        browse = undefined;
      }
    },
    interrupt: () => {
      if (view.selection !== undefined) view.selection = undefined;
      else handle?.cancel();
    },
    scroll: (to) => {
      const step = Math.max(1, view.scroll.state.height - 1);
      if (to === "pageUp") view.scroll.scrollBy(-step);
      else if (to === "pageDown") view.scroll.scrollBy(step);
      else if (to === "top") view.scroll.scrollTo(0);
      else view.scroll.followTail();
    },
    switchFocus: () => {
      tui.focus(tui.focused === composer ? view : composer);
    },
    activate: () => {
      const caret = view.caret;
      if (caret !== undefined) view.activate(caret);
    },
    copy: () => {
      const selection = view.selection;
      if (selection !== undefined) tui.copy(view.text({ from: selection.anchor, to: selection.head }));
    },
  });
  return pane;
}
