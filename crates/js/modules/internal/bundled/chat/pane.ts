/**
 * One chat pane: its transcript, its composer, its folds, and the `ChatSession` of its session.
 * An unbound pane creates its session at the first send or image paste.
 * The model and the reasoning come from `choice.json`, else from a picker.
 */

import { ChatComposer, ChatDocument, type ChatQuestion, ChatQuestions, ChatSession } from "yuke:chat";
import type { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { FRAME_MS, workingText } from "yuke:internal/bundled/chat/working";
import { EMPTY, IMAGE, joined, PASTE_SPAN } from "yuke:internal/chat/composer";
import { inputText } from "yuke:internal/chat/document";
import { STYLE } from "yuke:internal/chat/rows";
import { bottom } from "yuke:internal/tui/layout";
import type { Frozen, PluginContext, SessionHandle } from "yuke:plugins";
import type { Input, InputId, SessionId, SessionSettings, Usage } from "yuke:protocol";
import type { Status } from "yuke:transcript";
import {
  type Canvas,
  type CommandItem,
  type EditorState,
  fit,
  fuzzyMatch,
  type JsonValue,
  type Mount,
  measure,
  Picker,
  type Placement,
  type Size,
  strokeOf,
  TextEditor,
  TextView,
  type Tui,
  type View,
} from "yuke:tui";

const RULE = Object.freeze({ dim: true });

/** The selected command of the list above the composer. */
const SELECTED = Object.freeze({ reverse: true });

/** The most rows of a picker of a pane. */
const PICKER_ROWS = 12;

/** The most rows of the command list above the composer. */
const SLASH_ROWS = 6;

/** The label of the command `name` in the list: a slash, and the name. A core command shows without its prefix. */
function commandLabel(name: string): string {
  return `/${name.startsWith("core:") ? name.slice("core:".length) : name}`;
}

/** A draft of one slash word, such as `/mod`. */
const SLASH_WORD = /^\/\S*$/;

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
  /** Put the image of the clipboard at the caret of the composer. */
  readonly pasteImage: () => void;
  /**
   * Recall the newest waiting message of the user into an empty composer, and each next older one above the recalled
   * text. When no message waits, show an older message of the user.
   */
  readonly older: () => void;
  readonly canOlder: () => boolean;
  /** Show a newer message of the user, or the empty composer after the newest one. */
  readonly newer: () => void;
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
  /** A question of a plugin shows, so the composer takes no message. */
  readonly asking: () => boolean;
  /** Answer the shown question with a cancel. */
  readonly cancelQuestion: () => void;
  /** The session of the pane. */
  readonly session: () => SessionId | undefined;
  /**
   * Show the session `id`. The draft stays with the old session, and the draft of `id` comes back. It rejects when the
   * open fails or a send, a model choice, an image paste, or a recall runs.
   */
  readonly show: (id: SessionId) => Promise<void>;
  /** What the status bar shows of the session of the pane. `bound` is true when the pane has a session. */
  readonly status: () => {
    readonly bound: boolean;
    readonly settings: Frozen<SessionSettings> | undefined;
    readonly usage: Frozen<Usage> | undefined;
    readonly jobs: number;
  };
}

/** What each pane of the chat shares. */
export interface Chat {
  readonly ctx: PluginContext<{
    readonly copyOnRelease?: boolean | undefined;
    readonly questions?: "composer" | "modal" | undefined;
  }>;
  readonly tui: Tui;
  /** Where a question shows: in the place of the composer, or in a modal above the focused pane. */
  readonly questions: "composer" | "modal";
  /** The actions of each pane, by its view. */
  readonly panes: WeakMap<View, PaneActions>;
  /** Show the status items of the focused pane again. A pane calls it after each change of its session or transcript. */
  readonly refresh: () => void;
  /** The saved pick of a new session. */
  readonly choice: SavedChoice;
  /** Tell the listeners of the `chat` service that the pane `view` shows another session. */
  readonly moved: (view: View) => void;
}

/**
 * A chat pane: the transcript above a rule and the composer. The composer takes at most half the pane height. A pane
 * with a session holds its own handle until the mount closes.
 */
export function chatPane(chat: Chat, mount: Mount, state: PaneState): View {
  const ctx = chat.ctx;
  const tui = chat.tui;
  const chatSession = new ChatSession(ctx.get("sessions"), mount.signal, state.session);
  // The draft of each session that this pane left by `show`, for the return to it.
  const drafts = new Map<SessionId, EditorState>();
  // The session that the document belongs to.
  let bound = chatSession.id;
  let document = new ChatDocument(`session:${bound ?? "new"}`, state.folds);
  // The events of the session change the transcript, and the next layout projects it once.
  let dirty = true;
  // The status of the transcript at the last change, so a new retry starts its countdown once.
  let status: Status | undefined;
  // The saved place waits until its item loads.
  let restore = state.viewport;
  // One send, model choice, image paste, or show at a time. Another send, model choice, or image paste does nothing
  // until it ends, also while a picker is open, and a show rejects.
  let busy = false;
  // The start of the running turn on the clock of the tui, and the end of the wait of a scheduled retry.
  let working: number | undefined;
  let retryAt: number | undefined;
  // The cancel of the next frame of the spinner, so a turn that ends stops its loop.
  let stopTick: (() => void) | undefined;
  // The modal of the shown question, when questions show in a modal.
  let modal: { readonly asked: ChatQuestion; readonly mount: Mount } | undefined;
  /** Draw the working row again at the next frame of its spinner, while the turn runs. */
  const tick = (): void => {
    stopTick = working === undefined || mount.signal.aborted ? undefined : tui.after(FRAME_MS, tick);
  };
  /** Hide the working row and stop its spinner, at the end of a turn or of the handle. */
  const stopWorking = (): void => {
    working = undefined;
    // The retry status of the transcript can outlive its turn, so the next turn shows no old countdown.
    retryAt = undefined;
    stopTick?.();
    stopTick = undefined;
  };

  const changed = (): void => {
    dirty = true;
    tui.requestFrame();
    chat.refresh();
  };

  // The pane follows each change of its session: the working row, the question, and the next layout.
  chatSession.onChange(() => {
    const transcript = chatSession.transcript;
    if (chatSession.id !== bound) {
      // The first session of a pane keeps its folds. Another session starts without folds, at the tail.
      document = new ChatDocument(`session:${chatSession.id}`, bound === undefined ? document.folds : undefined);
      if (bound !== undefined) {
        restore = undefined;
        view.scroll.followTail();
      }
      bound = chatSession.id;
      stopWorking();
      chat.moved(pane);
    }
    // The working row counts from the first running state that the pane sees, and a retry counts down from its event.
    // An ended handle gets no more events, so its last state does not count.
    if (chatSession.handle !== undefined && transcript.state === "running") {
      if (working === undefined) {
        working = tui.now();
        tick();
      }
    } else stopWorking();
    const next = transcript.status;
    if (next !== status && next?.kind === "retry_scheduled") retryAt = tui.now() + next.afterMs;
    status = next;
    changed();
  });

  /** Open the session `id` of a restored pane. A failure gives one notice, and the next send opens it again. */
  const openSaved = (id: SessionId): void => {
    chatSession.open(id).catch((error: unknown) => {
      if (!mount.signal.aborted) ctx.notify("error", `the session ${id} did not open: ${String(error)}`);
    });
  };

  /**
   * Show the first open question in a modal, and close the modal of a closed one. A modal opens only while this pane
   * has the focus, so it waits for another modal to close.
   */
  function placeQuestion(): void {
    const asked = questions.current;
    if (modal !== undefined && modal.asked !== asked) modal.mount.close();
    if (asked === undefined || chat.questions !== "modal" || modal !== undefined) return;
    if (tui.focused !== composer && tui.focused !== view) return;
    const overlay = tui.overlay(() => asked.view, { place: (size) => bottom(size, asked.rows) });
    modal = { asked, mount: overlay };
    const close = (): void => overlay.close();
    mount.signal.addEventListener("abort", close, { once: true });
    overlay.signal.addEventListener(
      "abort",
      () => {
        mount.signal.removeEventListener("abort", close);
        if (modal?.mount === overlay) modal = undefined;
      },
      { once: true },
    );
  }

  const group = {};
  const view = new TextView({
    document: document.project(chatSession.transcript),
    role: "transcript",
    group,
    copyOnRelease: chat.ctx.options.copyOnRelease,
    followTail: true,
    activate: (position, link) => {
      const transcript = chatSession.transcript;
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
    requestOlder: () => chatSession.older(),
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
  // A draft of one slash word shows the commands that match it above the composer. Its keys come before the keymap of
  // the chat. Esc hides the list until the next edit, and a draft with no match stays a message.
  let slashHidden: string | undefined;
  let slashAt = 0;
  /** The enabled commands that match the slash word of the draft, the best first. */
  const slashMatches = (): readonly CommandItem[] => {
    const text = composer.state.text;
    if (!SLASH_WORD.test(text) || text === slashHidden || questions.current !== undefined) return [];
    const ranked = tui.commands.list().flatMap((item, index) => {
      const match = item.enabled ? fuzzyMatch(text, commandLabel(item.name)) : undefined;
      return match === undefined ? [] : [{ item, score: match.score, index }];
    });
    return ranked.sort((a, b) => b.score - a.score || a.index - b.index).map((entry) => entry.item);
  };
  extension.onKey((event) => {
    const matches = slashMatches();
    // A pane without a row above the rule shows no list, so the list takes no key.
    if (matches.length === 0 || ruleRow <= 0) return false;
    const stroke = strokeOf(event);
    if (stroke === "up" || stroke === "down") {
      slashAt = Math.max(
        0,
        Math.min(matches.length - 1, Math.min(slashAt, matches.length - 1) + (stroke === "up" ? -1 : 1)),
      );
      tui.requestFrame();
      return true;
    }
    if (stroke === "esc") {
      slashHidden = composer.state.text;
      tui.requestFrame();
      return true;
    }
    if (stroke !== "enter") return false;
    const command = matches[Math.min(slashAt, matches.length - 1)];
    if (command === undefined) return false;
    const draft = composer.state;
    composer.reset(EMPTY);
    // A command that left the registry runs nothing, so the draft comes back.
    if (!tui.commands.run(command.name)) composer.reset(draft);
    return true;
  }, "beforeKeymap");
  extension.onChange((change) => {
    if (change.kind !== "selection") slashAt = 0;
    // A cleared or changed draft ends the hide, so the same word typed again shows the list.
    if (composer.state.text !== slashHidden) slashHidden = undefined;
  });
  const chatComposer = new ChatComposer(chatSession, composer, { handle: () => sessionHandle(), signal: mount.signal });

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
          place: (size) => bottom(size, PICKER_ROWS),
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
   * Return the settings of the saved choice, else the settings that the user picks.
   * With `pick`, the picker opens and the saved choice does not count.
   */
  const settingsOf = async (pick: boolean): Promise<SessionSettings | undefined> => {
    const providers = (await ctx.get("catalog").list()).providers;
    const models = providers.flatMap((provider) => provider.models.map((model) => ({ provider: provider.id, model })));
    const saved = pick ? undefined : await chat.choice.loaded();
    let chosen = models.find(
      (entry) => entry.provider === saved?.model.provider && entry.model.id === saved?.model.model,
    );
    let reasoning = chosen?.model.reasoning.find((choice) => choice.level === saved?.reasoning);
    if (chosen === undefined || reasoning === undefined) {
      chosen = await choose(models, (entry) => `${entry.provider}/${entry.model.id}`);
      if (chosen === undefined) return undefined;
      reasoning = await choose(chosen.model.reasoning, (choice) => choice.level);
      if (reasoning === undefined) return undefined;
      const choice = { model: { provider: chosen.provider, model: chosen.model.id }, reasoning: reasoning.level };
      try {
        await chat.choice.save(choice);
      } catch (error) {
        // The session can start without the saved choice. The next new pane asks again.
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
      cwd: tui.startup.cwd,
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
      const current = chatSession.transcript.settings;
      if (current === undefined) throw new Error(`the session ${id} is not open`);
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

  /** Send the draft. A refused input comes back in the composer, with a notice. */
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
  const older = async (): Promise<void> => {
    try {
      const result = await chatComposer.older();
      if (result === "taken" && !mount.signal.aborted) ctx.notify("info", "the message reached the turn already");
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the message did not come back: ${String(error)}`);
    }
  };

  /** Put the image of the clipboard at the caret. The pane gets its session first, because the image goes to its store. */
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
      const target = await sessionHandle();
      if (target === undefined || mount.signal.aborted) return;
      const blob = await target.putBlob(image.bytes);
      if (mount.signal.aborted) return;
      // The image goes where the caret is now, also after an edit during the paste.
      const count = composer.state.spans.filter((span) => span.kind === "image").length;
      const selection = composer.selection;
      composer.replace(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head), IMAGE, [
        { from: 0, to: 1, kind: "image", label: `[image ${count + 1}]`, media: { blob, mime: image.mime } },
      ]);
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the image did not attach: ${String(error)}`);
    } finally {
      busy = false;
    }
  };

  const questions = new ChatQuestions(chatSession, {
    signal: mount.signal,
    failed: (error) => ctx.notify("error", `the answer did not reach the plugin: ${String(error)}`),
  });
  questions.onChange(() => {
    placeQuestion();
    changed();
  });
  // A modal question waits for the focus of this pane.
  if (chat.questions === "modal") {
    const stop = tui.onFocus(() => placeQuestion());
    mount.signal.addEventListener("abort", stop, { once: true });
  }
  // The open comes after the views, because its snapshot can show a question.
  if (chatSession.id !== undefined) openSaved(chatSession.id);

  // The layout keeps the row of the rule and the shown waiting messages for the draw. Without a free row, the pane
  // draws no rule.
  let ruleRow = -1;
  let slashRows = 0;
  let shown: [InputId, Frozen<Input>][] = [];
  const pane: View = {
    contexts: ["chat"],
    layout(size: Size): readonly Placement[] {
      if (dirty) {
        dirty = false;
        view.setDocument(document.project(chatSession.transcript));
      }
      // A question in the composer place hides the composer, and the composer keeps its draft.
      const question = chat.questions === "composer" ? questions.current : undefined;
      // The composer keeps one row in a pane of any size, and at most half of a taller pane.
      const wanted = question?.rows ?? composer.heightFor(size.width);
      const composerRows = Math.min(wanted, Math.max(1, Math.floor(size.height / 2)));
      const composerRow = Math.max(0, size.height - composerRows);
      ruleRow = composerRow - 1;
      // The command list sits on the rule, and the working row sits on the list while a turn runs.
      slashRows = Math.min(SLASH_ROWS, slashMatches().length, Math.max(0, ruleRow));
      const workingRows = working !== undefined && ruleRow - slashRows > 0 ? 1 : 0;
      // The strip takes the rows above the working row that its messages need, and the transcript gets the rest. When
      // rows run out, the strip keeps the newest messages.
      const list = chatComposer.waiting;
      const above = Math.max(0, ruleRow - slashRows - workingRows);
      shown = list.slice(Math.max(0, list.length - above));
      const placements = [
        { view, rect: { column: 0, row: 0, width: size.width, height: Math.max(0, above - shown.length) } },
        {
          view: question?.view ?? composer,
          rect: { column: 0, row: composerRow, width: size.width, height: size.height - composerRow },
        },
      ];
      // The view has rows only after its own first layout. The saved place waits for a height, then for its item or
      // the end of the history.
      if (restore !== undefined && chatSession.handle !== undefined && view.scroll.state.height > 0) {
        const key = restore.key;
        if (view.document.items.some((item) => item.key === key)) {
          // A row past the end of a changed item gives its first row.
          if (!view.scroll.scrollToItem(key, restore.row)) view.scroll.scrollToItem(key);
          restore = undefined;
        } else if (chatSession.complete || chatSession.historyError !== undefined) restore = undefined;
        else void chatSession.older();
      }
      return placements;
    },
    draw(canvas: Canvas): void {
      if (ruleRow < 0) return;
      const workingRows = working !== undefined && ruleRow - slashRows > 0 ? 1 : 0;
      const slashRow = ruleRow - slashRows;
      for (const [at, entry] of shown.entries()) {
        const row = slashRow - workingRows - shown.length + at;
        const hint = at === shown.length - 1 ? " ↑ edit" : "";
        const text = inputText(entry[1].content).replaceAll("\n", " ");
        const room = Math.max(0, canvas.width - 1 - measure(hint));
        const cut = fit(text, room) === text.length ? text : `${text.slice(0, fit(text, room - 1))}…`;
        canvas.text(1, row, cut, STYLE.meta);
        if (hint !== "") canvas.text(canvas.width - measure(hint), row, hint, STYLE.hint);
      }
      if (working !== undefined && workingRows === 1) {
        // While the list shows, Esc hides the list, so the row shows no cancel key.
        const key = slashRows > 0 ? undefined : tui.keys.keysOf("chat:interrupt")[0];
        const row = workingText(chatSession.transcript, working, tui.now(), retryAt, key);
        canvas.text(0, slashRow - 1, row.spinner, STYLE.hint);
        const room = Math.max(0, canvas.width - 2);
        const text =
          fit(row.text, room) === row.text.length ? row.text : `${row.text.slice(0, fit(row.text, room - 1))}…`;
        canvas.text(2, slashRow - 1, text, STYLE.meta);
      }
      // The list scrolls so the selected command stays in sight.
      const matches = slashRows === 0 ? [] : slashMatches();
      const selected = Math.min(slashAt, matches.length - 1);
      const first = Math.max(0, selected - slashRows + 1);
      const width = Math.max(0, ...matches.map((item) => measure(commandLabel(item.name))));
      for (const [at, item] of matches.slice(first, first + slashRows).entries()) {
        const style = first + at === selected ? SELECTED : undefined;
        const label = commandLabel(item.name).padEnd(width);
        const text = `${label}  ${item.description ?? ""}`;
        const cut =
          fit(text, canvas.width - 1) === text.length ? text : `${text.slice(0, fit(text, canvas.width - 2))}…`;
        canvas.text(1, slashRow + at, cut.slice(0, label.length), style);
        canvas.text(
          1 + measure(label),
          slashRow + at,
          cut.slice(label.length),
          style === undefined ? STYLE.meta : style,
        );
      }
      canvas.text(0, ruleRow, "─".repeat(canvas.width), RULE);
      // The rule shows a failed history load, so the text stays in sight at any scroll place.
      const historyError = chatSession.historyError;
      if (historyError !== undefined) {
        canvas.text(1, ruleRow, ` the history did not load: ${String(historyError)} `, STYLE.error);
      } else if (view.scroll.state.changedBelow) canvas.text(1, ruleRow, " new output ↓ ", STYLE.hint);
    },
    get initialFocus(): View {
      return (chat.questions === "composer" ? questions.current?.focus : undefined) ?? composer;
    },
    snapshot: () => {
      const scroll = view.scroll.state;
      const viewport = restore ?? (scroll.following ? undefined : scroll.anchor);
      return {
        type: "pane",
        state: {
          ...(chatSession.id === undefined ? {} : { session: chatSession.id }),
          draft: composer.state as unknown as JsonValue,
          folds: document.folds,
          ...(viewport === undefined ? {} : { viewport: { key: viewport.key, row: viewport.row } }),
        },
      };
    },
  };
  chat.panes.set(pane, {
    session: () => chatSession.id,
    show: async (id) => {
      if (busy || chatComposer.busy) throw new Error("the pane is busy");
      const before = chatSession.id;
      busy = true;
      try {
        await chatSession.open(id);
      } finally {
        busy = false;
      }
      // A show of the shown session only opens it again after the end of its handle.
      if (mount.signal.aborted || id === before) return;
      // The draft of a session waits for the return to it. A pane without a session has no images in its draft, so the
      // draft goes with the pane, below the saved draft of `id`.
      const draft = composer.state;
      const saved = drafts.get(id);
      drafts.delete(id);
      if (before === undefined) {
        if (saved !== undefined) chatComposer.setDraft(joined(saved, draft));
      } else {
        if (draft.text !== "") drafts.set(before, draft);
        chatComposer.setDraft(saved ?? EMPTY);
      }
    },
    status: () => ({
      bound: chatSession.id !== undefined,
      settings: chatSession.transcript.settings,
      usage: chatSession.transcript.usage,
      jobs: chatSession.handle?.jobs().length ?? 0,
    }),
    toggleTools: () => {
      document.toggleTools(chatSession.transcript);
      changed();
    },
    send: () => void send(),
    chooseModel: () => void chooseModel(),
    pasteImage: () => void pasteImage(),
    browsing: () => chatComposer.browsing,
    // A waiting recall keeps ↑, so the key does not move the caret meanwhile.
    canOlder: () => chatComposer.canOlder,
    older: () => void older(),
    newer: () => chatComposer.newer(),
    clear: () => {
      if (composer.state.text === "") chatSession.handle?.cancel();
      else chatComposer.setDraft(EMPTY);
    },
    interrupt: () => {
      if (view.selection !== undefined) view.selection = undefined;
      else chatSession.handle?.cancel();
    },
    scroll: (to) => {
      const step = Math.max(1, view.scroll.state.height - 1);
      if (to === "pageUp") view.scroll.scrollBy(-step);
      else if (to === "pageDown") view.scroll.scrollBy(step);
      else if (to === "top") view.scroll.scrollTo(0);
      else view.scroll.followTail();
    },
    switchFocus: () => {
      const input = (chat.questions === "composer" ? questions.current?.focus : undefined) ?? composer;
      tui.focus(tui.focused === view ? input : view);
    },
    activate: () => {
      const caret = view.caret;
      if (caret !== undefined) view.activate(caret);
    },
    copy: () => {
      const selection = view.selection;
      if (selection !== undefined) tui.copy(view.text({ from: selection.anchor, to: selection.head }));
    },
    asking: () => questions.current !== undefined,
    cancelQuestion: () => questions.cancel(),
  });
  return pane;
}
