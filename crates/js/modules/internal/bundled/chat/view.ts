/**
 * The view of the chat: its transcript, its composer, its folds, and two `ChatSession`s. The root is the session that
 * the composer sends to, and the chat holds it also while a child of the root shows read-only. A chat without a root
 * creates one at the first send or image paste. `/new` lets go of the root, and the next root starts in the folder of
 * the root before. The model and the reasoning come from `choice.json`, else from a picker.
 */

import type {
  ChatPresentation,
  ChatPresentationOptions,
  ChatView,
  CompletionProvider,
  ComposerContext,
  ComposerFrame,
  ComposerPlace,
  ComposerView,
} from "yuke:chat";
import type { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { commandWordLength } from "yuke:internal/chat/commands";
import { ChatCompletions } from "yuke:internal/chat/completions";
import { ChatComposer, EMPTY } from "yuke:internal/chat/composer";
import { ChatDocument, inputText } from "yuke:internal/chat/document";
import { ChatQuestions } from "yuke:internal/chat/questions";
import { clipped, STYLE } from "yuke:internal/chat/rows";
import { ChatSession } from "yuke:internal/chat/session";
import { ChatWorking } from "yuke:internal/chat/working";
import { failureOf } from "yuke:internal/failure";
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
  SPINNER_INTERVAL,
  TextEditor,
  TextView,
  type Tui,
  type View,
} from "yuke:tui";

/** The frame when no plugin sets a frame: one rule above the input, and one rule below it. */
const RULES: ComposerFrame = {
  inset: () => ({ top: 1, bottom: 1 }),
  draw: (canvas, chat) => {
    const rule = "─".repeat(canvas.width);
    const below = chat.inputRect.row + chat.inputRect.height;
    if (chat.inputRect.row > 0) canvas.text(0, 0, rule, STYLE.rule);
    if (below < canvas.height) canvas.text(0, below, rule, STYLE.rule);
  },
};

/** The item at the top of a scrolled transcript, and its row there. */
type Viewport = {
  readonly id: string;
  readonly row: number;
};

/**
 * The saved state of the chat: its root, the draft of its composer, its fold choices, the place of a transcript that
 * does not follow the tail, and the folder of the next root of a chat without one.
 */
export interface SavedChat {
  readonly session?: SessionId | undefined;
  readonly nextFolder?: string | undefined;
  readonly draft?: EditorState | undefined;
  readonly folds?: readonly (readonly [string, boolean])[] | undefined;
  readonly viewport?: Viewport | undefined;
}

/** What the commands of the plugin do in the chat. */
export interface ChatActions {
  /** The chat as the `chat` service gives it to a plugin. */
  readonly view: ChatView;
  /** It aborts when the view of the chat closes. */
  readonly signal: AbortSignal;
  readonly toggleTools: () => void;
  readonly send: () => Promise<void>;
  /** Let the user choose the model and the reasoning of the root. */
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
  /** Clear the draft. An empty draft cancels the running turn of the root. */
  readonly clear: () => void;
  /** Drop the selection of the transcript, else show the root again, else cancel the running turn of the root. */
  readonly interrupt: () => void;
  /** Move the waiting tool calls of the root to the background. */
  readonly moveJobsToBackground: () => void;
  readonly scroll: (to: "pageUp" | "pageDown" | "top" | "bottom") => void;
  /** A question of the root shows. */
  readonly asking: () => boolean;
  /** A child of the root shows. */
  readonly showsChild: () => boolean;
  /** The composer shows: no question and no child. */
  readonly composing: () => boolean;
  /** Whether the root can open the rename dialog. */
  readonly canRename: () => boolean;
  /** Rename the root in a dialog. */
  readonly rename: () => Promise<void>;
  /** Answer the shown question with a cancel. */
  readonly cancelQuestion: () => void;
  /**
   * Show the session `id`: a child of the root read-only, else as the new root. A new root asks before it stops the
   * work of the tree, then closes the old root and clears the draft. It rejects when the open fails or the chat is busy.
   */
  readonly show: (id: SessionId) => Promise<void>;
  /**
   * Show no session, with an empty composer. It asks before it stops the work of the tree, then closes the root. The
   * next message creates a root in the folder of the root before. A busy chat does nothing.
   */
  readonly newSession: () => Promise<void>;
  /**
   * What the status bar shows of the shown session. `bound` is true when the chat has a root. `nextFolder` is the
   * folder of a root that the chat creates.
   */
  readonly status: () => {
    readonly bound: boolean;
    readonly nextFolder: string;
    readonly settings: Frozen<SessionSettings> | undefined;
    readonly usage: Frozen<Usage> | undefined;
    readonly jobs: number;
  };
}

/** One call of `addComposerView`. The abort of `stop` ends its view in each view of the chat. */
export interface ComposerViewEntry {
  readonly place: ComposerPlace;
  readonly create: (mount: Mount, view: ChatView) => ComposerView;
  readonly stop: AbortController;
}

/** What each view of the chat shares. */
export interface Chat {
  /** The context of the chat plugin. A view reads no option. */
  readonly ctx: PluginContext<object>;
  readonly tui: Tui;
  /** Show the status items again. The view calls it after each change of its sessions or transcript. */
  readonly refresh: () => void;
  /** The saved pick of a new session. */
  readonly choice: SavedChoice;
  /** The first answer of the child labels of the `chat` service for `session`. */
  readonly childLabel: (session: SessionId) => string | undefined;
  /**
   * Ask whether to stop the turn and the jobs of the tree of `root` before a quit or a switch. `true` at once when
   * nothing runs, and `false` after a stay or while another confirmation shows.
   */
  readonly confirmStop: (root: SessionId | undefined, kind: "quit" | "switch") => Promise<boolean>;
  /** The factory of the `chat` service for the look of the transcript. Without one, the chat uses `ChatDocument`. */
  readonly presenter: () => ((options: ChatPresentationOptions) => ChatPresentation) | undefined;
  /** The views of the `chat` service at `place`, in add order. */
  readonly composerViews: (place: ComposerPlace) => readonly ComposerViewEntry[];
  /** The frame of the `chat` service around the input. Without one, the chat draws two rules. */
  readonly frame: () => ComposerFrame | undefined;
  /** The factory of the view of an empty chat, or `undefined` when an empty chat shows nothing. */
  readonly emptyView: () => ((mount: Mount, view: ChatView) => View) | undefined;
  /** Tell the listeners of the `chat` service that the chat shows another session. */
  readonly moved: () => void;
  /** Make `actions` the chat until the close of its mount, and start each view watcher of the `chat` service on it. */
  readonly opened: (actions: ChatActions) => void;
  /** The completion providers of the `chat` service, the newest first. */
  readonly completionProviders: () => readonly CompletionProvider[];
}

/**
 * The view of the chat: the transcript above the composer, in a frame that is two rules by default. The composer takes
 * at most half the height. The view holds the handles of its sessions until the mount closes.
 */
export function chatView(chat: Chat, mount: Mount, state: SavedChat): View {
  const ctx = chat.ctx;
  const tui = chat.tui;
  const sessions = ctx.get("sessions");
  const root = new ChatSession(sessions, { signal: mount.signal, id: state.session });
  const child = new ChatSession(sessions, { signal: mount.signal });
  /** The session that the transcript shows: the child, else the root. */
  const shown = (): ChatSession => (child.id === undefined ? root : child);
  let bound = root.id;
  // The folder that `/new` left keeps the next root there, also after a reload.
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
    return presenter?.({ id: key, folds, signal, requestUpdate: changed }) ?? new ChatDocument(key, folds);
  };
  /** The key of the document of the shown session. */
  const keyOf = (): string => `session:${shown().id ?? "new"}`;
  let document = create(keyOf(), state.folds);
  // The saved place waits until its item loads.
  let restore = state.viewport;
  // One send, model choice, image paste, show, `/new`, or rename at a time. Another send, model choice, image paste, or
  // `/new` does nothing until it ends, also while a picker or a confirmation is open, and a show rejects.
  let busy = false;
  const rootWorking = new ChatWorking(root, { signal: mount.signal, now: () => tui.now() });
  const childWorking = new ChatWorking(child, { signal: mount.signal, now: () => tui.now() });
  /** The working state of the shown session. */
  const working = (): ChatWorking => (child.id === undefined ? rootWorking : childWorking);
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
      if (shown().transcript.entries.some((entry) => entry.kind === "tool" && entry.startedAt !== undefined)) {
        dirty = true;
      }
    }
    stopTick = working().active && !mount.signal.aborted ? tui.addTimer(SPINNER_INTERVAL, tick) : undefined;
  };
  const restartTick = (): void => {
    stopTick?.();
    tick();
  };
  rootWorking.addChangeListener(restartTick);
  childWorking.addChangeListener(restartTick);

  /** Follow each change of the sessions: the shown session, its folds, its place, and the next layout. */
  const follow = (): void => {
    const id = shown().id;
    if (id !== bound) {
      // The first root keeps the folds of the chat. Another session starts without folds, at the tail.
      document = create(keyOf(), bound === undefined ? document.folds : undefined);
      if (bound !== undefined) {
        restore = undefined;
        view.scroll.followTail();
      }
      bound = id;
      chat.moved();
      restartTick();
    }
    changed();
  };
  root.addChangeListener(follow);
  child.addChangeListener(follow);

  const group = {};
  const view = new TextView({
    document: document.project(root.transcript),
    role: "transcript",
    group,
    followTail: true,
    onActivate: (position, link) => {
      const transcript = shown().transcript;
      if (link === undefined) {
        if (position.section === "gap" || !document.toggle(transcript, position.item)) return;
        // The view stays where it is, also at the tail, and it scrolls the least to show the head line of the item.
        const top = view.scroll.state.top;
        const projected = document.project(transcript);
        view.setDocument(projected);
        view.scroll.scrollTo(top);
        const sections = projected.items.find((item) => item.id === position.item)?.sections;
        const head = sections?.find((section) => section.kind === "label");
        if (head !== undefined) view.ensureVisible({ item: position.item, section: head.id, offset: 0 });
        changed();
        return;
      }
      // A relative target starts in the folder of its tool call, else in the folder of the session, else at the start.
      const entry = transcript.entries.find((candidate) => candidate.id === position.item);
      const folder =
        (entry?.kind === "tool" ? entry.folder : undefined) ?? transcript.settings?.folder ?? tui.startup.folder;
      const absolute = /^[a-z][a-z0-9+.-]*:/i.test(link) || link.startsWith("/");
      const target = absolute ? link : `${folder.replace(/\/$/, "")}/${link}`;
      tui.clipboard.writeText(target);
      ctx.notify("info", `Copied ${target}`);
    },
    onTopReached: () => shown().loadOlderHistory(),
  });
  const composer = new TextEditor({
    role: "composer",
    group,
    placeholder: "Message…",
    state: state.draft,
  });
  // Only the composer shows the list, and a chat without a row above the frame shows no list.
  const completions = new ChatCompletions(composer, {
    providers: () => chat.completionProviders(),
    folder: () => root.transcript.settings?.folder ?? nextFolder ?? tui.startup.folder,
    signal: mount.signal,
    enabled: () => composing() && frameRow > 0,
    onError: (error) => ctx.notify("error", `A completion failed: ${failureOf(error)}`),
  });
  completions.addChangeListener(() => tui.requestFrame());
  // The word of a draft that Enter runs as a command gets its style, so a user sees it before the key.
  const composerExtension = composer.extend(mount.signal);
  const markCommand = (): void => {
    const length = commandWordLength(tui.commands, composer.state.text);
    composerExtension.setDecorations(
      length === 0 ? [] : [{ range: { anchor: 0, head: length }, style: STYLE.command }],
    );
  };
  composerExtension.addChangeListener((change) => {
    if (change.kind !== "selection") markCommand();
  });
  markCommand();
  const chatComposer = new ChatComposer(root, composer, { handle: () => sessionHandle(), signal: mount.signal });

  /** Give the error notice `text` with `error`, unless the view closed: its close ends the work with no notice. */
  const fail = (text: string, error: unknown): void => {
    if (!mount.signal.aborted) ctx.notify("error", `${text}: ${String(error)}`);
  };

  /** Start the view of the plugin factory `create` in the mount `own`. A failed factory gives a notice and no view. */
  const startPluginView = <V extends View>(create: (mount: Mount, view: ChatView) => V, own: Mount): V | undefined =>
    startView(
      ctx.name,
      (given) => create(given, viewFields),
      own,
      (_source, text) => ctx.notify("error", text),
    );

  /** Run `task` as the one action of the chat, unless another one runs. A failure gives the notice `text`. */
  const exclusive = async (text: string, task: () => Promise<void>): Promise<void> => {
    if (busy) return;
    busy = true;
    try {
      await task();
    } catch (error) {
      fail(text, error);
    } finally {
      busy = false;
    }
  };

  /**
   * Return the settings of the saved choice, else the settings that the user picks.
   * With `pick`, the picker opens and the saved choice does not count.
   */
  const settingsOf = async (pick: boolean): Promise<SessionSettings | undefined> => {
    const providers = (await ctx.get("catalog").list()).providers;
    const models = providers.flatMap((provider) => provider.models.map((model) => ({ provider: provider.id, model })));
    if (models.length === 0) {
      ctx.notify("info", "No provider is ready: run /login");
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
        ctx.notify("error", `yuke could not save the model choice: ${String(error)}`);
      }
    }
    return {
      model: { provider: chosen.provider, model: chosen.model.id },
      settings: { reasoning: reasoning.settings, toolChoice: "auto" },
      folder: nextFolder ?? tui.startup.folder,
    };
  };

  /**
   * Let the user choose the model and the level, and save the choice for new sessions. A chat with a root also saves
   * them in the root. The root keeps its folder and the rest of its settings.
   */
  const chooseModel = (): Promise<void> =>
    exclusive("yuke could not change the model", async () => {
      const settings = await settingsOf(true);
      if (settings === undefined || root.id === undefined) return;
      const target = await sessionHandle();
      if (target === undefined) return;
      // A handle comes after the snapshot, and the snapshot gives the settings.
      const current = root.transcript.settings as Frozen<SessionSettings>;
      const reasoning = settings.settings.reasoning;
      await target.setSettings({ ...current, model: settings.model, settings: { ...current.settings, reasoning } });
    });

  /**
   * The handle of the root. A chat without a root uses the saved choice, else a picker. Return `undefined` after a
   * cancel, or after a failure of the models or of the open that gave its notice.
   */
  const sessionHandle = async (): Promise<SessionHandle | undefined> => {
    const id = root.id;
    try {
      return await root.ensure(async () => {
        try {
          return await settingsOf(false);
        } catch (error) {
          fail("The models did not load", error);
          return undefined;
        }
      });
    } catch (error) {
      // The failure of a new session goes to the caller.
      if (id === undefined) throw error;
      fail(`The session ${id} did not open`, error);
      return undefined;
    }
  };

  const send = (): Promise<void> => exclusive("yuke could not send the message", () => chatComposer.send());

  /** Recall a waiting message or show an older message. A failed recall or a message that a turn took gives a notice. */
  const olderMessage = async (): Promise<void> => {
    try {
      const result = await chatComposer.olderMessage();
      if (result === "taken") ctx.notify("info", "The turn already has the message");
    } catch (error) {
      fail("yuke could not get the message back", error);
    }
  };

  /** Put the image of the clipboard at the caret. */
  const pasteImage = (): Promise<void> =>
    exclusive("yuke could not attach the image", async () => {
      const image = await tui.clipboard.readImage();
      if (image === undefined) {
        ctx.notify("info", "There is no image on the clipboard");
        return;
      }
      await chatComposer.attachImage(image);
    });

  /** The row in place of the composer while a child shows. It takes the focus, and no key edits a draft. */
  const childRow: View = {
    focusable: true,
    draw(canvas: Canvas): void {
      const key = tui.keys.list("chat:interrupt")[0];
      const text = child.id === undefined ? "" : (chat.childLabel(child.id) ?? "Child session");
      canvas.text(0, 0, clipped(key === undefined ? text : `${text} · ${key} back`, canvas.width), STYLE.meta);
    },
  };

  // The questions of the root, also while a child shows: a subagent asks through its parent.
  const questions = new ChatQuestions(root, {
    signal: mount.signal,
    onError: (error) => ctx.notify("error", `The answer did not reach the plugin: ${String(error)}`),
  });

  /** The composer shows: no question of the root and no child. */
  const composing = (): boolean => questions.current === undefined && child.id === undefined;

  /** The view that takes the typed keys: a question of the root, the row of a child, or the composer. */
  const input = (): View => questions.current?.view ?? (child.id === undefined ? composer : childRow);

  /** The chat is busy: a send, a model choice, an image paste, a recall, a show, `/new`, or a rename runs. */
  const occupied = (): boolean => busy || chatComposer.busy;

  /** Whether the chat can open its rename dialog without taking a competing action. */
  const canRename = (): boolean => root.id !== undefined && composing() && !occupied();

  /** Rename the root in a single-line dialog. The chat stays busy until the dialog closes. */
  const rename = async (): Promise<void> => {
    const id = root.id;
    if (id === undefined || !canRename()) return;
    busy = true;
    try {
      const row = await sessions.get(id);
      // A refused title stays in the field with its error.
      await tui.prompt({
        title: "Rename session",
        text: row.title ?? "",
        signal: mount.signal,
        onSubmit: (text) => sessions.rename(id, text),
      });
    } catch (error) {
      fail(`The session ${id} did not load`, error);
    } finally {
      busy = false;
      tui.requestFrame();
    }
  };

  // The open comes after the views, because its snapshot can show a question. A failure gives one notice, and the next
  // send opens the session again.
  const saved = root.id;
  if (saved !== undefined) {
    root.open(saved).catch((error: unknown) => {
      fail(`The session ${saved} did not open`, error);
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
  let strip: [InputId, Frozen<Input>][] = [];
  // The view of each call of `addComposerView` in this view, or `undefined` after its factory failed or it closed.
  const composerViews = new Map<ComposerViewEntry, ComposerView | undefined>();
  const viewFields: ChatView = {
    get composer() {
      return composer;
    },
    get sessionId() {
      return shown().id;
    },
    get rootId() {
      return root.id;
    },
    get transcript() {
      return shown().transcript;
    },
    get running() {
      return working().active;
    },
  };
  /** The views at `place` with their heights, which share `room` rows in add order. */
  const placedViews = (place: ComposerPlace, width: number, room: number) => {
    let left = room;
    return chat.composerViews(place).flatMap((entry) => {
      if (!composerViews.has(entry)) {
        // A view that closed itself stays closed, so its factory runs once in this view of the chat.
        const own = createMount(() => composerViews.set(entry, undefined));
        const stop = (): void => {
          own.close();
          composerViews.delete(entry);
        };
        entry.stop.signal.addEventListener("abort", stop, { once: true, signal: mount.signal });
        mount.signal.addEventListener("abort", () => own.close(), { once: true });
        composerViews.set(entry, startPluginView(entry.create, own));
      }
      const view = composerViews.get(entry);
      const height = view === undefined ? 0 : Math.min(view.heightFor(width), left);
      if (view === undefined || height <= 0) return [];
      left -= height;
      return [{ view, height }];
    });
  };
  // The view of the empty chat with the factory that made it, so a new factory makes a new view.
  let empty:
    | {
        readonly create: (mount: Mount, view: ChatView) => View;
        readonly view: View | undefined;
        readonly mount: Mount;
      }
    | undefined;
  mount.signal.addEventListener("abort", () => empty?.mount.close(), { once: true });
  /** The view of the empty chat: from the current factory, made once per factory. */
  const emptyView = (): View | undefined => {
    const create = chat.emptyView();
    if (empty?.create !== create) {
      empty?.mount.close();
      empty = undefined;
      if (create === undefined) return undefined;
      const own = createMount(() => {});
      empty = { create, view: startPluginView(create, own), mount: own };
    }
    return empty?.view;
  };
  /**
   * The chat is empty: it shows no child, and it has no root, or its root has no history, while no message waits, no
   * send runs, and no turn runs. A root that loads its history is not empty, so the empty view does not flash.
   */
  const isEmpty = (): boolean => {
    if (child.id !== undefined) return false;
    const transcript = root.transcript;
    if (transcript.pending.size > 0 || chatComposer.busy || rootWorking.active) return false;
    return root.id === undefined || (transcript.entries.length === 0 && root.historyComplete);
  };
  /** The placements of `views` in a column from `row`. */
  const stacked = (
    views: readonly { readonly view: ComposerView; readonly height: number }[],
    row: number,
    width: number,
  ) => {
    let at = row;
    return views.map((entry) => {
      const rect = { column: 0, row: at, width, height: entry.height };
      at += entry.height;
      return { view: entry.view, rect };
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
  const outer: View = {
    contexts: ["chat"],
    layout(size: Size): readonly Placement[] {
      // A plugin can load after the chat mounts.
      if (presenter !== chat.presenter()) {
        presenter = chat.presenter();
        document = create(keyOf(), document.folds);
        dirty = true;
      }
      if (dirty) {
        // A view at the tail shows none of the older history, so memory keeps only the newest events. A saved place
        // waits for its item, so the history stays until that item shows.
        if (restore === undefined && view.scroll.state.following) shown().trimHistory();
        dirty = false;
        view.setDocument(document.project(shown().transcript));
      }
      // A question and the row of a child hide the composer, and the composer keeps its draft.
      const question = questions.current;
      const below = placedViews("below", size.width, Math.floor(size.height / 2));
      const left = size.height - below.reduce((rows, entry) => rows + entry.height, 0);
      frame = chat.frame() ?? RULES;
      const kind = question !== undefined ? "question" : child.id !== undefined ? "child" : "composer";
      frameContext = { ...viewFields, width: size.width, kind };
      const inset = frame.inset(frameContext);
      const top = inset.top ?? 0;
      const insetLeft = inset.left ?? 0;
      const inputWidth = Math.max(0, size.width - insetLeft - (inset.right ?? 0));
      // A short chat gives up the rows below the input first, then the rows above it.
      const bottom = left >= top + 1 + (inset.bottom ?? 0) ? (inset.bottom ?? 0) : 0;
      const usable = left - bottom;
      // The composer keeps one row in a chat of any size, and at most half of a taller chat.
      const wanted = kind === "child" ? 1 : (question?.rows ?? composer.heightFor(inputWidth));
      const composerRows = Math.min(wanted, Math.max(1, Math.floor(usable / 2)));
      const composerRow = Math.max(0, usable - composerRows);
      const topRows = Math.min(top, composerRow);
      frameRow = composerRow - topRows;
      const frameRows = topRows + usable - composerRow + bottom;
      inputRect = { column: insetLeft, row: topRows, width: inputWidth, height: usable - composerRow };
      // The command list sits on the frame. While a turn runs, the working row sits above the list.
      listRows = Math.min(completions.rows, frameRow);
      const free = frameRow - listRows;
      const workingRow = working().active && free > 0 ? 1 : 0;
      // The strip takes the rows above the working row that the messages of the root need. When rows run out, the strip
      // keeps the newest messages. A child shows no strip.
      const list = child.id === undefined ? chatComposer.waitingMessages : [];
      const above = Math.max(0, free - workingRow);
      strip = list.slice(Math.max(0, list.length - above));
      // Plugin views get the rows that the strip leaves, at most half the rows above the frame.
      const aboveViews = placedViews("above", size.width, Math.min(above - strip.length, Math.floor(frameRow / 2)));
      const aboveRows = aboveViews.reduce((rows, entry) => rows + entry.height, 0);
      // One empty row goes below the transcript, and a running turn adds one below the working row. The transcript gets
      // the other rows. The chat adds an empty row only when the transcript keeps a row, so a short chat drops it first.
      let transcriptRows = above - strip.length - aboveRows;
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
        { view: completions.view, rect: { column: 0, row: frameRow - listRows, width: size.width, height: listRows } },
        ...stacked(aboveViews, frameRow - listRows - workingRows - strip.length - aboveRows, size.width),
        ...stacked(below, left, size.width),
      ];
      // The view has rows only after its own first layout. The saved place waits for a height, then for its item or
      // the end of the history.
      if (restore !== undefined && shown().handle !== undefined && view.scroll.state.height > 0) {
        const key = restore.id;
        if (view.document.items.some((item) => item.id === key)) {
          // A row past the end of a changed item gives its first row.
          if (!view.scroll.scrollToItem(key, restore.row)) view.scroll.scrollToItem(key);
          restore = undefined;
        } else if (shown().historyComplete || shown().historyError !== undefined) restore = undefined;
        else void shown().loadOlderHistory();
      }
      return placements;
    },
    draw(canvas: Canvas): void {
      const listRow = frameRow - listRows;
      const stripRow = listRow - workingRows - strip.length;
      for (const [at, entry] of strip.entries()) {
        const row = stripRow + at;
        const hint = at === strip.length - 1 ? " ↑ edit" : "";
        const text = inputText(entry[1].content).replaceAll("\n", " ");
        const room = Math.max(0, canvas.width - 1 - measure(hint));
        canvas.text(1, row, clipped(text, room), STYLE.meta);
        if (hint !== "") canvas.text(canvas.width - measure(hint), row, hint, STYLE.hint);
      }
      // While the list shows, Esc hides the list, and a child shows no cancel key: Esc goes back to the root.
      const key = listRows > 0 || child.id !== undefined ? undefined : tui.keys.list("chat:interrupt")[0];
      const row =
        workingRows > 0
          ? working().text({
              cancelKey: key,
              backgroundKey: child.id === undefined ? tui.keys.list("chat:background")[0] : undefined,
              width: Math.max(0, canvas.width - 2),
            })
          : undefined;
      if (row !== undefined) {
        canvas.text(0, listRow - workingRows, row.spinner, STYLE.hint);
        canvas.text(2, listRow - workingRows, clipped(row.text, Math.max(0, canvas.width - 2)), STYLE.meta);
      }
      // The empty row below the transcript shows a failed history load, so the text stays in sight at any scroll place.
      if (noticeRow < 0) return;
      const historyError = shown().historyError;
      if (historyError !== undefined) {
        canvas.text(1, noticeRow, `the history did not load: ${String(historyError)}`, STYLE.error);
      } else if (view.scroll.state.changedBelow) canvas.text(1, noticeRow, "new output ↓", STYLE.hint);
    },
    get initialFocus(): View {
      return input();
    },
    snapshot: (): JsonValue => {
      // The folds and the place of a shown child do not fit the saved root, so a reload shows the root at the tail.
      const rootShows = child.id === undefined;
      const scroll = view.scroll.state;
      const viewport = rootShows ? (restore ?? (scroll.following ? undefined : scroll.anchor)) : undefined;
      return {
        ...(root.id !== undefined ? { session: root.id } : nextFolder !== undefined ? { nextFolder } : {}),
        draft: composer.state as unknown as JsonValue,
        ...(rootShows ? { folds: document.folds } : {}),
        ...(viewport === undefined ? {} : { viewport }),
      };
    },
  };
  /** Close the session `id` for each holder, so its jobs and subagents stop. A failure gives a notice. */
  const close = (id: SessionId): void => {
    sessions.closeForAll(id).catch((error: unknown) => fail(`The session ${id} did not close`, error));
  };
  const show = async (id: SessionId): Promise<void> => {
    if (occupied()) throw new Error("the chat is busy");
    busy = true;
    try {
      // An open of the shown root holds it again after the end of its handle.
      if (id === root.id) {
        child.leave();
        await root.open(id);
        return;
      }
      // The saved parent decides, so a child of an earlier process shows as a child too.
      const before = root.id;
      if (before !== undefined && (await sessions.get(id)).parent === before) {
        await child.open(id);
        return;
      }
      if (!(await chat.confirmStop(before, "switch"))) return;
      await root.open(id);
      child.leave();
      if (before === undefined) return;
      // A pasted image of the draft belongs to the old root.
      chatComposer.setDraft(EMPTY);
      close(before);
    } finally {
      busy = false;
    }
  };
  const newSession = async (): Promise<void> => {
    const before = root.id;
    if (occupied() || before === undefined) return;
    busy = true;
    try {
      if (!(await chat.confirmStop(before, "switch"))) return;
    } finally {
      busy = false;
    }
    nextFolder = root.transcript.settings?.folder ?? nextFolder;
    chatComposer.setDraft(EMPTY);
    child.leave();
    root.leave();
    close(before);
  };
  const actions: ChatActions = {
    view: viewFields,
    signal: mount.signal,
    show,
    newSession,
    status: () => ({
      bound: root.id !== undefined,
      nextFolder: nextFolder ?? tui.startup.folder,
      settings: shown().transcript.settings,
      usage: shown().transcript.usage,
      // A plugin shows its own jobs, as a subagent list does, so the bar counts only the commands. The transcript has the
      // running jobs in order with the other updates, while the chat holds the session.
      jobs:
        shown().handle === undefined
          ? 0
          : [...shown().transcript.jobs.values()].filter((job) => job.kind === "process").length,
    }),
    toggleTools: () => {
      document.toggleTools(shown().transcript);
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
      if (composer.state.text === "") root.handle?.cancelTurn();
      else chatComposer.setDraft(EMPTY);
    },
    moveJobsToBackground: () => root.handle?.moveJobsToBackground(),
    interrupt: () => {
      if (view.selection !== undefined) view.selection = undefined;
      else if (child.id !== undefined) child.leave();
      else root.handle?.cancelTurn();
    },
    scroll: (to) => {
      const step = Math.max(1, view.scroll.state.height - 1);
      if (to === "pageUp") view.scroll.scrollBy(-step);
      else if (to === "pageDown") view.scroll.scrollBy(step);
      else if (to === "top") view.scroll.scrollTo(0);
      else view.scroll.followTail();
    },
    asking: () => questions.current !== undefined,
    showsChild: () => child.id !== undefined,
    composing,
    canRename,
    rename,
    cancelQuestion: () => questions.cancel(),
  };
  chat.opened(actions);
  return outer;
}
