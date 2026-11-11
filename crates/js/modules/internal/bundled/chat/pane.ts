/**
 * One chat pane: its transcript, its composer, its folds, and the `ChatSession` of its session.
 * An unbound pane creates its session at the first send or image paste. `/new` unbinds a pane, and its next session
 * starts in the folder of the session that it left.
 * The model and the reasoning come from `choice.json`, else from a picker.
 */

import {
  ChatCommands,
  ChatComposer,
  ChatDocument,
  type ChatPane,
  type ChatPresentation,
  type ChatPresentationOptions,
  ChatQuestions,
  type ChatReadOnly,
  ChatSession,
  ChatWorking,
  type ComposerContext,
  type ComposerFrame,
  type ComposerPlace,
  type ComposerView,
} from "yuke:chat";
import type { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { EMPTY } from "yuke:internal/chat/composer";
import { inputText } from "yuke:internal/chat/document";
import { clipped, STYLE } from "yuke:internal/chat/rows";
import { createMount, startView } from "yuke:internal/tui/mount";
import type { Frozen, PluginContext, SessionHandle } from "yuke:plugins";
import type { Input, InputId, SessionId, SessionSettings, Usage } from "yuke:protocol";
import {
  type Canvas,
  type EditorState,
  type JsonValue,
  type Mount,
  measure,
  type Placement,
  type Rect,
  type Size,
  TextEditor,
  TextView,
  type Tui,
  type View,
} from "yuke:tui";

/** The frame when no plugin sets a frame: one rule above the input, and one rule below it. */
const RULES: ComposerFrame = {
  inset: () => ({ top: 1, bottom: 1 }),
  draw: (canvas, pane) => {
    const rule = "─".repeat(canvas.width);
    const below = pane.inputRect.row + pane.inputRect.height;
    if (pane.inputRect.row > 0) canvas.text(0, 0, rule, STYLE.rule);
    if (below < canvas.height) canvas.text(0, below, rule, STYLE.rule);
  },
};

/** The item at the top of a scrolled transcript, and its row there. */
interface Viewport {
  readonly key: string;
  readonly row: number;
}

/**
 * The saved state of a pane: the session that it shows, the draft of its composer, its fold choices, the place of a
 * transcript that does not follow the tail, and the folder of the next session of a pane without a session.
 */
export interface PaneState {
  readonly session?: SessionId | undefined;
  readonly nextFolder?: string | undefined;
  readonly draft?: EditorState | undefined;
  readonly folds?: readonly (readonly [string, boolean])[] | undefined;
  readonly viewport?: Viewport | undefined;
}

/** What the commands of the plugin do in a pane. */
export interface PaneActions {
  readonly toggleTools: () => void;
  readonly send: () => Promise<void>;
  /** Let the user choose the model and the reasoning of the pane. */
  readonly chooseModel: () => Promise<void>;
  /** Put the image of the clipboard at the caret of the composer. */
  readonly pasteImage: () => Promise<void>;
  /**
   * Recall the newest waiting message of the user into an empty composer, and each next older one above the recalled
   * text. When no message waits, show an older message of the user.
   */
  readonly olderMessage: () => Promise<void>;
  readonly canOlderMessage: () => boolean;
  /** Show a newer message of the user, or the empty composer after the newest one. */
  readonly newerMessage: () => void;
  readonly browsing: () => boolean;
  /** Clear the draft. An empty draft cancels the running turn. */
  readonly clear: () => void;
  /** Drop the selection of the transcript, else cancel the running turn. */
  readonly interrupt: () => void;
  /** Move the waiting tool calls of the session to the background. */
  readonly moveJobsToBackground: () => void;
  readonly scroll: (to: "pageUp" | "pageDown" | "top" | "bottom") => void;
  /** A question of a plugin shows, so the composer takes no message. */
  readonly asking: () => boolean;
  /** The session of the pane is read-only. */
  readonly locked: () => boolean;
  /** Whether the session can open the rename dialog. */
  readonly canRename: () => boolean;
  /** Rename the session in a dialog. */
  readonly rename: () => Promise<void>;
  /** The session that a quit names to resume: the session of the pane, or the parent of a read-only one. */
  readonly resumeSession: () => SessionId | undefined;
  /** Answer the shown question with a cancel. */
  readonly cancelQuestion: () => void;
  /** The session of the pane. */
  readonly session: () => SessionId | undefined;
  /**
   * Show the session `id`. The draft stays with the old session, and the draft of `id` comes back. It rejects when the
   * open fails or a send, a model choice, an image paste, or a recall runs.
   */
  readonly show: (id: SessionId) => Promise<void>;
  /**
   * Show no session, with an empty composer. The next message creates a session in the folder of the session before.
   * The session before keeps its work. A busy pane does nothing.
   */
  readonly newSession: () => void;
  /**
   * What the status bar shows of the session of the pane. `bound` is true when the pane has a session. `nextFolder`
   * is the folder of a session that the pane creates.
   */
  readonly status: () => {
    readonly bound: boolean;
    readonly nextFolder: string;
    readonly settings: Frozen<SessionSettings> | undefined;
    readonly usage: Frozen<Usage> | undefined;
    readonly jobs: number;
  };
}

/** One call of `addComposerView`. The abort of `stop` ends its view in each pane. */
export interface ComposerViewEntry {
  readonly place: ComposerPlace;
  readonly create: (mount: Mount, pane: ChatPane) => ComposerView;
  readonly stop: AbortController;
}

/** What each pane of the chat shares. */
export interface Chat {
  /** The context of the chat plugin. A pane reads no option. */
  readonly ctx: PluginContext<object>;
  readonly tui: Tui;
  /** The actions of each open pane, by its view. A pane leaves the map when its mount closes. */
  readonly panes: Map<View, PaneActions>;
  /** Show the status items of the focused pane again. A pane calls it after each change of its session or transcript. */
  readonly refresh: () => void;
  /** The saved pick of a new session. */
  readonly choice: SavedChoice;
  /** The first answer of the read-only sources of the `chat` service for `session`. */
  readonly readOnly: (session: SessionId) => ChatReadOnly | undefined;
  /** The factory of the `chat` service for the look of the transcript. Without one, a pane uses `ChatDocument`. */
  readonly presenter: () => ((options: ChatPresentationOptions) => ChatPresentation) | undefined;
  /** The views of the `chat` service at `place`, in add order. */
  readonly composerViews: (place: ComposerPlace) => readonly ComposerViewEntry[];
  /** The frame of the `chat` service around the input. Without one, a pane draws two rules. */
  readonly frame: () => ComposerFrame | undefined;
  /** The factory of the view of an empty pane, or `undefined` when an empty pane shows nothing. */
  readonly emptyView: () => ((mount: Mount, pane: ChatPane) => View) | undefined;
  /** Tell the listeners of the `chat` service that the pane `view` shows another session. */
  readonly moved: (view: View) => void;
}

/**
 * A chat pane: the transcript above the composer, in a frame that is two rules by default. The composer takes at most
 * half the pane height. A pane with a session holds its own handle until the mount closes.
 */
export function chatPane(chat: Chat, mount: Mount, state: PaneState): View {
  const ctx = chat.ctx;
  const tui = chat.tui;
  const chatSession = new ChatSession(ctx.get("sessions"), { signal: mount.signal, id: state.session });
  // The draft of each session that this pane left by `show`, for the return to it.
  const drafts = new Map<SessionId, EditorState>();
  let bound = chatSession.id;
  // The folder that `/new` left keeps the next session there, also after a reload.
  let nextFolder = state.nextFolder;
  // The events of the session change the transcript, and the next layout projects it once.
  let dirty = true;
  const changed = (): void => {
    dirty = true;
    tui.requestFrame();
    chat.refresh();
  };
  let presenter = chat.presenter();
  let scope = new AbortController();
  /** Abort the signal of the old presentation, and create a presentation with the document `key`. */
  const create = (key: string, folds: ChatPresentationOptions["folds"]): ChatPresentation => {
    scope.abort();
    scope = new AbortController();
    const signal = AbortSignal.any([mount.signal, scope.signal]);
    return presenter?.({ key, folds, signal, requestUpdate: changed }) ?? new ChatDocument(key, folds);
  };
  /** The key of the document of the shown session. */
  const keyOf = (): string => `session:${chatSession.id ?? "new"}`;
  let document = create(keyOf(), state.folds);
  // The saved place waits until its item loads.
  let restore = state.viewport;
  // One send, model choice, image paste, show, or rename at a time. Another send, model choice, image paste, or `/new`
  // does nothing until it ends, also while a picker is open, and a show rejects.
  let busy = false;
  const working = new ChatWorking(chatSession, { signal: mount.signal, now: () => tui.now() });
  // The cancel of the next frame of the spinner, so a turn that ends stops its loop.
  let stopTick: (() => void) | undefined;
  // The wall-clock second of the last check for a running tool.
  let checkedSecond = 0;
  /** Draw the working row again at the next frame of its spinner, while the turn runs. */
  const tick = (): void => {
    // The head line of a running tool shows whole seconds, so the next layout projects once a second.
    const second = Math.floor(Date.now() / 1000);
    if (second !== checkedSecond) {
      checkedSecond = second;
      if (chatSession.transcript.entries.some((entry) => entry.kind === "tool" && entry.startedAt !== undefined)) {
        dirty = true;
      }
    }
    stopTick = working.active && !mount.signal.aborted ? tui.after(working.frameMs, tick) : undefined;
  };
  working.onChange(() => {
    stopTick?.();
    tick();
  });

  // The pane follows each change of its session: the folds, the place, and the next layout.
  chatSession.onChange(() => {
    if (chatSession.id !== bound) {
      // The first session of a pane keeps its folds. Another session starts without folds, at the tail.
      document = create(keyOf(), bound === undefined ? document.folds : undefined);
      if (bound !== undefined) {
        restore = undefined;
        view.scroll.followTail();
      }
      bound = chatSession.id;
      chat.moved(pane);
    }
    changed();
  });

  const group = {};
  const view = new TextView({
    document: document.project(chatSession.transcript),
    role: "transcript",
    group,
    followTail: true,
    activate: (position, link) => {
      const transcript = chatSession.transcript;
      if (link === undefined) {
        if (position.section === "gap" || !document.toggle(transcript, position.item)) return;
        // The view stays where it is, also at the tail, and it scrolls the least to show the head line of the item.
        const top = view.scroll.state.top;
        const projected = document.project(transcript);
        view.setDocument(projected);
        view.scroll.scrollTo(top);
        const sections = projected.items.find((item) => item.key === position.item)?.sections;
        const head = sections?.find((section) => section.kind === "label");
        if (head !== undefined) view.ensureVisible({ item: position.item, section: head.key, offset: 0 });
        changed();
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
    onTopReached: () => chatSession.loadOlderHistory(),
  });
  const composer = new TextEditor({
    role: "composer",
    group,
    placeholder: "Message…",
    state: state.draft,
  });
  // A question takes the place of the list, and a pane without a row above the frame shows no list.
  const commands = new ChatCommands(composer, {
    commands: tui.commands,
    signal: mount.signal,
    enabled: () => questions.current === undefined && locked() === undefined && frameRow > 0,
  });
  const chatComposer = new ChatComposer(chatSession, composer, { handle: () => sessionHandle(), signal: mount.signal });

  /**
   * Return the settings of the saved choice, else the settings that the user picks.
   * With `pick`, the picker opens and the saved choice does not count.
   */
  const settingsOf = async (pick: boolean): Promise<SessionSettings | undefined> => {
    const providers = (await ctx.get("catalog").list()).providers;
    const models = providers.flatMap((provider) => provider.models.map((model) => ({ provider: provider.id, model })));
    if (models.length === 0) {
      ctx.notify("info", "no provider is ready: run /login");
      return undefined;
    }
    const saved = pick ? undefined : chat.choice.current;
    let chosen = models.find(
      (entry) => entry.provider === saved?.model.provider && entry.model.id === saved?.model.model,
    );
    let reasoning = chosen?.model.reasoning.find((choice) => choice.level === saved?.reasoning);
    if (chosen === undefined || reasoning === undefined) {
      chosen = await tui.select({
        items: models,
        label: (entry) => `${entry.provider}/${entry.model.id}`,
        signal: mount.signal,
      });
      if (chosen === undefined) return undefined;
      reasoning = await tui.select({
        items: chosen.model.reasoning,
        label: (choice) => choice.level,
        signal: mount.signal,
      });
      if (reasoning === undefined) return undefined;
      const choice = { model: { provider: chosen.provider, model: chosen.model.id }, reasoning: reasoning.level };
      try {
        await chat.choice.save(choice);
        // The first send uses the saved choice, so the status bar shows it.
        chat.refresh();
      } catch (error) {
        // The session can start without the saved choice.
        ctx.notify("error", `the model choice did not save: ${String(error)}`);
      }
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
      cwd: nextFolder ?? tui.startup.cwd,
    };
  };

  /**
   * Let the user choose the model and the level, and save the choice for new panes.
   * A pane with a session also saves them in the session.
   * The session keeps its folder and the rest of its settings.
   */
  const chooseModel = async (): Promise<void> => {
    if (busy) return;
    busy = true;
    try {
      const settings = await settingsOf(true);
      if (settings === undefined || mount.signal.aborted) return;
      const id = chatSession.id;
      if (id === undefined) return;
      const target = await sessionHandle();
      if (target === undefined || mount.signal.aborted) return;
      // A handle comes after the snapshot, and the snapshot gives the settings.
      const current = chatSession.transcript.settings as Frozen<SessionSettings>;
      const reasoning = settings.settings.reasoning;
      await target.setSettings({ ...current, model: settings.model, settings: { ...current.settings, reasoning } });
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the model did not change: ${String(error)}`);
    } finally {
      busy = false;
    }
  };

  /**
   * The handle of the session of this pane. A pane without a session uses the saved choice, else a picker. Return
   * `undefined` after a cancel, or after a failure of the models or of the open that gave its notice.
   */
  const sessionHandle = async (): Promise<SessionHandle | undefined> => {
    const id = chatSession.id;
    try {
      return await chatSession.ensure(async () => {
        try {
          return await settingsOf(false);
        } catch (error) {
          if (!mount.signal.aborted) ctx.notify("error", `the models did not load: ${String(error)}`);
          return undefined;
        }
      });
    } catch (error) {
      // The failure of a new session goes to the caller.
      if (id === undefined) throw error;
      if (!mount.signal.aborted) ctx.notify("error", `the session ${id} did not open: ${String(error)}`);
      return undefined;
    }
  };

  const send = async (): Promise<void> => {
    if (busy) return;
    busy = true;
    try {
      await chatComposer.send();
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the message did not send: ${String(error)}`);
    } finally {
      busy = false;
    }
  };

  /** Recall a waiting message or show an older message. A failed recall or a message that a turn took gives a notice. */
  const olderMessage = async (): Promise<void> => {
    try {
      const result = await chatComposer.olderMessage();
      if (result === "taken" && !mount.signal.aborted) ctx.notify("info", "the message reached the turn already");
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the message did not come back: ${String(error)}`);
    }
  };

  /** Put the image of the clipboard at the caret. */
  const pasteImage = async (): Promise<void> => {
    if (busy) return;
    busy = true;
    try {
      const image = await tui.readImage();
      if (mount.signal.aborted) return;
      if (image === undefined) {
        ctx.notify("info", "the clipboard holds no image");
        return;
      }
      await chatComposer.attachImage(image);
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the image did not attach: ${String(error)}`);
    } finally {
      busy = false;
    }
  };

  /** The read-only answer for the session of the pane. */
  const locked = (): ChatReadOnly | undefined =>
    chatSession.id === undefined ? undefined : chat.readOnly(chatSession.id);

  /** The row in place of the composer of a read-only session. It takes the focus, and no key edits a draft. */
  const lockedRow: View = {
    focusable: true,
    draw(canvas: Canvas): void {
      const key = tui.keys.keysOf("chat:interrupt")[0];
      const text = locked()?.text ?? "";
      canvas.text(0, 0, clipped(key === undefined ? text : `${text} · ${key} back`, canvas.width), STYLE.meta);
    },
  };

  /** The view that takes the typed keys: the row of a read-only session, a question, or the composer. */
  const input = (): View => (locked() === undefined ? (questions.current?.view ?? composer) : lockedRow);

  const questions = new ChatQuestions(chatSession, {
    signal: mount.signal,
    onError: (error) => ctx.notify("error", `the answer did not reach the plugin: ${String(error)}`),
  });

  /** The pane is busy: a send, a model choice, an image paste, a recall, a show, or a rename runs. */
  const occupied = (): boolean => busy || chatComposer.busy;

  /** Whether the pane can open its rename dialog without taking a competing pane action. */
  const canRename = (): boolean =>
    chatSession.id !== undefined && questions.current === undefined && locked() === undefined && !occupied();

  /** Rename the session in a single-line dialog. The pane stays busy until the dialog closes. */
  const rename = async (): Promise<void> => {
    if (!canRename()) return;
    const id = chatSession.id;
    if (id === undefined) return;
    busy = true;
    try {
      const row = await ctx.get("sessions").get(id);
      if (mount.signal.aborted || chatSession.id !== id) {
        busy = false;
        return;
      }
      let errorText: string | undefined;
      let pending = false;
      let dialog: Mount | undefined;
      const title = row.session.title ?? "";
      const editor = new TextEditor({
        multiline: false,
        state: {
          text: title,
          selection: { anchor: title.length, head: title.length },
          spans: [],
        },
        submit: (state) => {
          if (pending || dialog?.signal.aborted === true) return;
          pending = true;
          void ctx
            .get("sessions")
            .rename(id, state.text)
            .then(
              () => dialog?.close(),
              (reason: unknown) => {
                if (dialog === undefined || dialog.signal.aborted) return;
                errorText = String(reason);
                pending = false;
                tui.requestFrame();
              },
            );
        },
      });
      const body: View = {
        focusable: true,
        initialFocus: editor,
        layout: (size) => [
          {
            view: editor,
            rect: {
              column: 0,
              row: 0,
              width: size.width,
              height: Math.max(1, size.height - (errorText === undefined ? 0 : 1)),
            },
          },
        ],
        draw: (canvas) => {
          if (errorText !== undefined) canvas.text(0, canvas.height - 1, clipped(errorText, canvas.width), STYLE.error);
        },
      };
      dialog = tui.dialog({ title: () => "Rename session", body, signal: mount.signal });
      dialog.signal.addEventListener(
        "abort",
        () => {
          busy = false;
          dialog = undefined;
          if (!ctx.signal.aborted) tui.requestFrame();
        },
        { once: true },
      );
    } catch (error) {
      busy = false;
      if (!mount.signal.aborted) ctx.notify("error", `the session ${id} did not load: ${String(error)}`);
    }
  };

  // The open comes after the views, because its snapshot can show a question. A failure gives one notice, and the next
  // send opens the session again.
  const saved = chatSession.id;
  if (saved !== undefined) {
    chatSession.open(saved).catch((error: unknown) => {
      if (!mount.signal.aborted) ctx.notify("error", `the session ${saved} did not open: ${String(error)}`);
    });
  }

  // The layout keeps the place of the frame and the shown waiting messages for the draw.
  let frame = RULES;
  let frameContext: ComposerContext;
  let frameRow = 0;
  let inputRect: Rect = { column: 0, row: 0, width: 0, height: 0 };
  let noticeRow = -1;
  let listRows = 0;
  let workingRows = 0;
  let shown: [InputId, Frozen<Input>][] = [];
  // The view of each call of `addComposerView` in this pane, or `undefined` after its factory failed or it closed.
  const composerViews = new Map<ComposerViewEntry, ComposerView | undefined>();
  const chatPaneFields: ChatPane = {
    get view() {
      return pane;
    },
    get session() {
      return chatSession.id;
    },
    get transcript() {
      return chatSession.transcript;
    },
    get running() {
      return working.active;
    },
  };
  /** The views at `place` with their heights, which share `room` rows in add order. */
  const placedViews = (place: ComposerPlace, width: number, room: number) => {
    let left = room;
    return chat.composerViews(place).flatMap((entry) => {
      if (!composerViews.has(entry)) {
        // A view that closed itself stays closed, so its factory runs once in this pane.
        const child = createMount(() => composerViews.set(entry, undefined));
        const stop = (): void => {
          child.close();
          composerViews.delete(entry);
        };
        entry.stop.signal.addEventListener("abort", stop, { once: true });
        mount.signal.addEventListener(
          "abort",
          () => {
            entry.stop.signal.removeEventListener("abort", stop);
            child.close();
          },
          { once: true },
        );
        const created = startView(
          ctx.name,
          (own) => entry.create(own, chatPaneFields),
          child,
          (_source, text) => ctx.notify("error", text),
        );
        composerViews.set(entry, created as ComposerView | undefined);
      }
      const shown = composerViews.get(entry);
      const height = shown === undefined ? 0 : Math.min(shown.heightFor(width), left);
      if (shown === undefined || height <= 0) return [];
      left -= height;
      return [{ view: shown, height }];
    });
  };
  // The view of the empty pane with the factory that made it, so a new factory makes a new view.
  let empty: { readonly create: (mount: Mount, pane: ChatPane) => View; readonly view: View | undefined } | undefined;
  let emptyMount: Mount | undefined;
  mount.signal.addEventListener("abort", () => emptyMount?.close(), { once: true });
  /** The view of the empty pane: from the current factory, made once per factory. */
  const emptyView = (): View | undefined => {
    const create = chat.emptyView();
    if (empty?.create !== create) {
      emptyMount?.close();
      emptyMount = undefined;
      empty = undefined;
      if (create === undefined) return undefined;
      const child = createMount(() => {});
      emptyMount = child;
      const view = startView(
        ctx.name,
        (own) => create(own, chatPaneFields),
        child,
        (_source, text) => ctx.notify("error", text),
      );
      empty = { create, view };
    }
    return empty?.view;
  };
  /**
   * The pane is empty: it has no session, or its session has no history, while no message waits, no send runs, and no
   * turn runs. A session that loads its history is not empty, so the empty view does not flash.
   */
  const isEmpty = (): boolean => {
    const transcript = chatSession.transcript;
    if (transcript.pending.size > 0 || chatComposer.busy || working.active) return false;
    return chatSession.id === undefined || (transcript.entries.length === 0 && chatSession.historyComplete);
  };
  /** The placements of `views` in a column from `row`. */
  const stacked = (
    views: readonly { readonly view: ComposerView; readonly height: number }[],
    row: number,
    width: number,
  ) => {
    let at = row;
    return views.map(({ view: shown, height }) => {
      const rect = { column: 0, row: at, width, height };
      at += height;
      return { view: shown, rect };
    });
  };
  /** The frame around the input: its view places the input, so a click and the cursor stay local to the input. */
  const frameView: View = {
    get style() {
      return frame.style;
    },
    layout: () => [{ view: input(), rect: inputRect }],
    draw(canvas: Canvas, focused: boolean): void {
      frame.draw(canvas, { ...frameContext, focused, inputRect: inputRect });
    },
  };
  const pane: View = {
    contexts: ["chat"],
    layout(size: Size): readonly Placement[] {
      // A plugin can load after the start pane mounts.
      if (presenter !== chat.presenter()) {
        presenter = chat.presenter();
        document = create(keyOf(), document.folds);
        dirty = true;
      }
      if (dirty) {
        dirty = false;
        view.setDocument(document.project(chatSession.transcript));
      }
      // A question and a read-only row hide the composer, and the composer keeps its draft.
      const question = questions.current;
      const below = placedViews("below", size.width, Math.floor(size.height / 2));
      const left = size.height - below.reduce((rows, entry) => rows + entry.height, 0);
      frame = chat.frame() ?? RULES;
      const kind = locked() !== undefined ? "readOnly" : question !== undefined ? "question" : "composer";
      frameContext = { ...chatPaneFields, width: size.width, kind };
      const inset = frame.inset(frameContext);
      const top = inset.top ?? 0;
      const insetLeft = inset.left ?? 0;
      const inputWidth = Math.max(0, size.width - insetLeft - (inset.right ?? 0));
      // A short pane gives up the rows below the input first, then the rows above it.
      const bottom = left >= top + 1 + (inset.bottom ?? 0) ? (inset.bottom ?? 0) : 0;
      const usable = left - bottom;
      // The composer keeps one row in a pane of any size, and at most half of a taller pane.
      const wanted = kind === "readOnly" ? 1 : (question?.rows ?? composer.heightFor(inputWidth));
      const composerRows = Math.min(wanted, Math.max(1, Math.floor(usable / 2)));
      const composerRow = Math.max(0, usable - composerRows);
      const topRows = Math.min(top, composerRow);
      frameRow = composerRow - topRows;
      const frameRows = topRows + usable - composerRow + bottom;
      inputRect = { column: insetLeft, row: topRows, width: inputWidth, height: usable - composerRow };
      // The command list sits on the frame. While a turn runs, the working row sits above the list.
      listRows = Math.min(commands.rows, frameRow);
      const free = frameRow - listRows;
      const workingRow = working.active && free > 0 ? 1 : 0;
      // The strip takes the rows above the working row that its messages need. When rows run out, the strip keeps the
      // newest messages.
      const list = chatComposer.waiting;
      const above = Math.max(0, free - workingRow);
      shown = list.slice(Math.max(0, list.length - above));
      // Plugin views get the rows that the strip leaves, at most half the rows above the frame.
      const aboveViews = placedViews("above", size.width, Math.min(above - shown.length, Math.floor(frameRow / 2)));
      const aboveRows = aboveViews.reduce((rows, entry) => rows + entry.height, 0);
      // One empty row goes below the transcript, and a running turn adds one below the working row. The transcript gets
      // the other rows. A pane adds an empty row only when the transcript keeps a row, so a short pane drops it first.
      let transcriptRows = above - shown.length - aboveRows;
      const gap = transcriptRows > 1 ? 1 : 0;
      transcriptRows -= gap;
      const workingGap = workingRow === 1 && transcriptRows > 1 ? 1 : 0;
      transcriptRows -= workingGap;
      workingRows = workingRow + workingGap;
      noticeRow = gap === 1 ? transcriptRows : -1;
      const transcriptRect = { column: 0, row: 0, width: size.width, height: transcriptRows };
      // The empty view draws over the transcript, which keeps the focus and the scroll state.
      const emptyShown = isEmpty() ? emptyView() : undefined;
      const placements = [
        { view, rect: transcriptRect },
        ...(emptyShown === undefined ? [] : [{ view: emptyShown, rect: transcriptRect }]),
        { view: frameView, rect: { column: 0, row: frameRow, width: size.width, height: frameRows } },
        { view: commands.view, rect: { column: 0, row: frameRow - listRows, width: size.width, height: listRows } },
        ...stacked(aboveViews, frameRow - listRows - workingRows - shown.length - aboveRows, size.width),
        ...stacked(below, left, size.width),
      ];
      // The view has rows only after its own first layout. The saved place waits for a height, then for its item or
      // the end of the history.
      if (restore !== undefined && chatSession.handle !== undefined && view.scroll.state.height > 0) {
        const key = restore.key;
        if (view.document.items.some((item) => item.key === key)) {
          // A row past the end of a changed item gives its first row.
          if (!view.scroll.scrollToItem(key, restore.row)) view.scroll.scrollToItem(key);
          restore = undefined;
        } else if (chatSession.historyComplete || chatSession.historyError !== undefined) restore = undefined;
        else void chatSession.loadOlderHistory();
      }
      return placements;
    },
    draw(canvas: Canvas): void {
      const listRow = frameRow - listRows;
      const stripRow = listRow - workingRows - shown.length;
      for (const [at, entry] of shown.entries()) {
        const row = stripRow + at;
        const hint = at === shown.length - 1 ? " ↑ edit" : "";
        const text = inputText(entry[1].content).replaceAll("\n", " ");
        const room = Math.max(0, canvas.width - 1 - measure(hint));
        canvas.text(1, row, clipped(text, room), STYLE.meta);
        if (hint !== "") canvas.text(canvas.width - measure(hint), row, hint, STYLE.hint);
      }
      // While the list shows, Esc hides the list, so the row shows no cancel key.
      const key = listRows > 0 || locked() !== undefined ? undefined : tui.keys.keysOf("chat:interrupt")[0];
      const row =
        workingRows > 0
          ? working.text({
              cancelKey: key,
              backgroundKey: locked() === undefined ? tui.keys.keysOf("chat:background")[0] : undefined,
              width: Math.max(0, canvas.width - 2),
            })
          : undefined;
      if (row !== undefined) {
        canvas.text(0, listRow - workingRows, row.spinner, STYLE.hint);
        canvas.text(2, listRow - workingRows, clipped(row.text, Math.max(0, canvas.width - 2)), STYLE.meta);
      }
      // The empty row below the transcript shows a failed history load, so the text stays in sight at any scroll place.
      if (noticeRow < 0) return;
      const historyError = chatSession.historyError;
      if (historyError !== undefined) {
        canvas.text(1, noticeRow, `the history did not load: ${String(historyError)}`, STYLE.error);
      } else if (view.scroll.state.changedBelow) canvas.text(1, noticeRow, "new output ↓", STYLE.hint);
    },
    get initialFocus(): View {
      return input();
    },
    snapshot: () => {
      const scroll = view.scroll.state;
      const viewport = restore ?? (scroll.following ? undefined : scroll.anchor);
      return {
        type: "pane",
        state: {
          ...(chatSession.id !== undefined
            ? { session: chatSession.id }
            : nextFolder !== undefined
              ? { nextFolder }
              : {}),
          draft: composer.state as unknown as JsonValue,
          folds: document.folds,
          ...(viewport === undefined ? {} : { viewport: { key: viewport.key, row: viewport.row } }),
        },
      };
    },
  };
  /** Keep the draft of the session `before` for the return to it, and restore the draft of the session `after`. */
  const swapDraft = (before: SessionId | undefined, after: SessionId): void => {
    // A pane without a session has no images in its draft, so the draft goes with the pane, and an older draft of
    // `after` would come back later.
    if (before === undefined) {
      drafts.delete(after);
      return;
    }
    const draft = composer.state;
    if (draft.text !== "") drafts.set(before, draft);
    chatComposer.setDraft(drafts.get(after) ?? EMPTY);
    drafts.delete(after);
  };
  const show = async (id: SessionId): Promise<void> => {
    if (occupied()) throw new Error("the pane is busy");
    const before = chatSession.id;
    busy = true;
    try {
      await chatSession.open(id);
    } finally {
      busy = false;
    }
    // A show of the shown session only opens it again after the end of its handle.
    if (mount.signal.aborted || id === before) return;
    swapDraft(before, id);
  };
  const newSession = (): void => {
    if (occupied()) return;
    // The server keeps a session with a turn or a job open after the pane lets go of it.
    const running = working.active || (chatSession.handle?.jobs().length ?? 0) > 0;
    nextFolder = chatSession.transcript.settings?.cwd ?? nextFolder;
    chatComposer.setDraft(EMPTY);
    chatSession.leave();
    if (running) ctx.notify("info", "the work goes on: /sessions shows it");
  };
  const actions: PaneActions = {
    session: () => chatSession.id,
    show,
    newSession,
    status: () => ({
      bound: chatSession.id !== undefined,
      nextFolder: nextFolder ?? tui.startup.cwd,
      settings: chatSession.transcript.settings,
      usage: chatSession.transcript.usage,
      // A plugin shows its own jobs, as a subagent list does, so the bar counts only the commands.
      jobs: chatSession.handle?.jobs().filter((job) => job.kind === "process").length ?? 0,
    }),
    toggleTools: () => {
      document.toggleTools(chatSession.transcript);
      changed();
    },
    send,
    chooseModel,
    pasteImage,
    browsing: () => chatComposer.browsing,
    // A waiting recall keeps ↑, so the key does not move the caret meanwhile.
    canOlderMessage: () => chatComposer.canOlderMessage,
    olderMessage,
    newerMessage: () => chatComposer.newerMessage(),
    clear: () => {
      if (composer.state.text === "") chatSession.handle?.cancel();
      else chatComposer.setDraft(EMPTY);
    },
    moveJobsToBackground: () => chatSession.handle?.moveJobsToBackground(),
    interrupt: () => {
      const back = locked()?.back;
      if (view.selection !== undefined) view.selection = undefined;
      else if (back === undefined) chatSession.handle?.cancel();
      else {
        show(back).catch((error: unknown) => {
          if (!mount.signal.aborted) ctx.notify("error", `the session ${back} did not open: ${String(error)}`);
        });
      }
    },
    scroll: (to) => {
      const step = Math.max(1, view.scroll.state.height - 1);
      if (to === "pageUp") view.scroll.scrollBy(-step);
      else if (to === "pageDown") view.scroll.scrollBy(step);
      else if (to === "top") view.scroll.scrollTo(0);
      else view.scroll.followTail();
    },
    asking: () => questions.current !== undefined || locked() !== undefined,
    locked: () => locked() !== undefined,
    canRename,
    rename,
    resumeSession: () => (chatSession.id === undefined ? undefined : (locked()?.back ?? chatSession.id)),
    cancelQuestion: () => questions.cancel(),
  };
  chat.panes.set(pane, actions);
  mount.signal.addEventListener("abort", () => chat.panes.delete(pane), { once: true });
  return pane;
}
