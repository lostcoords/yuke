/**
 * One chat pane: its transcript, its composer, its folds, and the handle of its session.
 * An unbound pane creates its session at the first send or image paste.
 * The model and the reasoning come from `choice.json`, else from a picker.
 */

import { FileSystemError, readTextFile, writeTextFile } from "yuke:fs";
import { blocksOf, draftOf, EMPTY, IMAGE, joined, PASTE_SPAN } from "yuke:internal/bundled/chat/composer";
import { type Asked, ask } from "yuke:internal/bundled/chat/questions";
import { STYLE } from "yuke:internal/bundled/chat/rows";
import { ChatDocument, inputText } from "yuke:internal/bundled/chat/transcript";
import type { EventsPage, Frozen, PluginContext, SessionHandle, ViewEvent } from "yuke:plugins";
import type {
  Input,
  InputId,
  InteractionId,
  InteractionResponse,
  ModelReference,
  ReasoningLevel,
  SessionId,
  SessionSettings,
  Usage,
} from "yuke:protocol";
import { type Entry, Transcript } from "yuke:transcript";
import {
  type Canvas,
  type EditorState,
  fit,
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
  /** What the status bar shows of the session of the pane. */
  readonly status: () => {
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
  readonly copyOnRelease: boolean;
  /** Where a question shows: in the place of the composer, or in a modal above the focused pane. */
  readonly questions: "composer" | "modal";
  /** The actions of each pane, by its view. */
  readonly panes: WeakMap<View, PaneActions>;
  /** Show the status items of the focused pane again. A pane calls it after each change of its session or transcript. */
  readonly refresh: () => void;
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
  // One send, model choice, or image paste at a time. Another one does nothing until it ends, also while a picker is
  // open.
  let busy = false;
  // The key of the shown message of a browse. A browse starts in an empty composer, so its end empties it again.
  let browse: string | undefined;
  // The last recalled pending input. The next ↑ recalls an older one, until an edit or a caret move.
  let recalled: InputId | undefined;
  // A recall waits for its removal. Until the removal ends, ↑ does nothing.
  let recalling = false;
  // The first open question of the session and its view. The others wait in order. A sent answer waits for the close.
  let asking:
    | { readonly id: InteractionId; readonly asked: Asked; answered: boolean; overlay: Mount | undefined }
    | undefined;
  const changed = (): void => {
    dirty = true;
    tui.requestFrame();
    chat.refresh();
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
    syncQuestion();
    changed();
    if (transcript.gap !== undefined) void load();
  };

  /**
   * Open the session `id` for this pane. A failure before the close of the pane gives one notice and no handle. The
   * next send, model choice, or image paste opens the session again, also after a close by another client.
   */
  const open = (id: SessionId): Promise<SessionHandle | undefined> =>
    sessions.open(id, { tail: TAIL, signal: mount.signal, event }).then(
      (opened) => {
        handle = opened;
        // The snapshot came before the handle, so its jobs show only now.
        chat.refresh();
        opened.signal.addEventListener(
          "abort",
          () => {
            // The close of the pane ends its handle too, and then nothing is left to do.
            if (handle !== opened || mount.signal.aborted) return;
            handle = undefined;
            opening = undefined;
            // No close update comes for the questions of an ended handle, and the next open shows them again.
            asking?.overlay?.close();
            asking = undefined;
            tui.requestFrame();
            chat.refresh();
          },
          { once: true },
        );
        return opened;
      },
      (error: unknown) => {
        opening = undefined;
        if (!mount.signal.aborted) ctx.notify("error", `the session ${id} did not open: ${String(error)}`);
        return undefined;
      },
    );

  /** Answer the shown question once. A failed answer, as after an answer of another client, gives a notice. */
  const answer = (response: InteractionResponse): void => {
    const current = asking;
    if (current === undefined || current.answered || handle === undefined) return;
    current.answered = true;
    try {
      handle.respond(current.id, response);
    } catch (error) {
      current.answered = false;
      ctx.notify("error", `the answer did not reach the plugin: ${String(error)}`);
    }
  };

  /**
   * Show the first open question, and drop the view of a closed one. A modal question opens only while this pane has
   * the focus, so it waits for another modal to close.
   */
  function syncQuestion(): void {
    const head = transcript.questions.entries().next().value;
    if (head?.[0] !== asking?.id) {
      asking?.overlay?.close();
      asking =
        head === undefined
          ? undefined
          : {
              id: head[0],
              asked: ask(head[1], () => transcript.questions.size, answer),
              answered: false,
              overlay: undefined,
            };
    }
    const current = asking;
    if (current === undefined || chat.questions !== "modal" || current.overlay !== undefined) return;
    if (tui.focused !== composer && tui.focused !== view) return;
    const overlay = tui.overlay(() => current.asked.view, {
      place: (size) => {
        const height = Math.min(current.asked.rows, size.height);
        return { column: 0, row: size.height - height, width: size.width, height };
      },
    });
    current.overlay = overlay;
    const close = (): void => overlay.close();
    mount.signal.addEventListener("abort", close, { once: true });
    overlay.signal.addEventListener(
      "abort",
      () => {
        mount.signal.removeEventListener("abort", close);
        current.overlay = undefined;
      },
      { once: true },
    );
  }

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
  // An edit of the shown message ends the browse, so the edited text stays. An edit or a caret move ends a recall,
  // so ↑ moves the caret again.
  extension.onChange((change) => {
    if (change.kind === "edit") browse = undefined;
    if (change.kind === "edit" || change.kind === "selection") recalled = undefined;
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
   * Return the settings of the saved choice, else the settings that the user picks.
   * With `pick`, the picker opens and the saved choice does not count.
   */
  const settingsOf = async (pick: boolean): Promise<SessionSettings | undefined> => {
    const providers = (await ctx.get("catalog").list()).providers;
    const models = providers.flatMap((provider) => provider.models.map((model) => ({ provider: provider.id, model })));
    let saved: { model: ModelReference; reasoning: ReasoningLevel } | undefined;
    if (!pick) {
      try {
        saved = JSON.parse(await readTextFile("choice.json", { baseDir: ctx.dataDir, fatal: true }));
      } catch (error) {
        if (!(error instanceof FileSystemError && error.code === "ENOENT")) {
          ctx.notify("error", `the model choice did not load: ${String(error)}`);
        }
      }
    }
    let chosen = models.find(
      (entry) => entry.provider === saved?.model?.provider && entry.model.id === saved?.model?.model,
    );
    let reasoning = chosen?.model.reasoning.find((choice) => choice.level === saved?.reasoning);
    if (chosen === undefined || reasoning === undefined) {
      chosen = await choose(models, (entry) => `${entry.provider}/${entry.model.id}`);
      if (chosen === undefined) return undefined;
      reasoning = await choose(chosen.model.reasoning, (choice) => choice.level);
      if (reasoning === undefined) return undefined;
      try {
        await writeTextFile(
          "choice.json",
          JSON.stringify({ model: { provider: chosen.provider, model: chosen.model.id }, reasoning: reasoning.level }),
          { baseDir: ctx.dataDir, atomic: true },
        );
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
      if (session === undefined) return;
      // A failed open gave its notice already.
      const target = await sessionHandle();
      if (target === undefined || mount.signal.aborted) return;
      const current = transcript.settings;
      if (current === undefined) throw new Error(`the session ${session} is not open`);
      const reasoning = settings.settings.reasoning;
      await target.setSettings({ ...current, model: settings.model, settings: { ...current.settings, reasoning } });
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the model did not change: ${String(error)}`);
    } finally {
      busy = false;
    }
  };

  /**
   * The handle of the session of this pane.
   * A pane without a session uses the saved choice, else a picker.
   * Return `undefined` after a cancel, or after a failure that gave its notice.
   */
  const sessionHandle = async (): Promise<SessionHandle | undefined> => {
    if (session === undefined) {
      let settings: SessionSettings | undefined;
      try {
        settings = await settingsOf(false);
      } catch (error) {
        if (!mount.signal.aborted) ctx.notify("error", `the models did not load: ${String(error)}`);
        return undefined;
      }
      if (settings === undefined || mount.signal.aborted) return undefined;
      const id = await sessions.create(settings);
      if (mount.signal.aborted) return undefined;
      session = id;
      document = new ChatDocument(`session:${id}`, document.folds);
      opening = open(id);
      changed();
    }
    // A failed open opens again here, and the open gives its own notice.
    opening ??= open(session);
    return handle ?? (await opening);
  };

  /**
   * Send the draft. The pane gets its session first, and a cancel keeps the draft. Then the composer clears, so the
   * user can type the next message. A refused input comes back above the newer text.
   */
  const send = async (): Promise<void> => {
    if (busy || blocksOf(composer.state).length === 0) return;
    busy = true;
    let draft: EditorState | undefined;
    try {
      const target = await sessionHandle();
      if (target === undefined || mount.signal.aborted) return;
      // The draft of the send is the one after the setup, so text typed meanwhile goes with it.
      draft = composer.state;
      const blocks = blocksOf(draft);
      if (blocks.length === 0) return;
      composer.reset(EMPTY);
      browse = undefined;
      recalled = undefined;
      await target.input(blocks);
    } catch (error) {
      if (mount.signal.aborted) return;
      if (draft !== undefined) {
        browse = undefined;
        recalled = undefined;
        composer.reset(joined(draft, composer.state));
      }
      ctx.notify("error", `the message did not send: ${String(error)}`);
    } finally {
      busy = false;
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

  // A modal question waits for the focus of this pane.
  if (chat.questions === "modal") {
    const stop = tui.onFocus(() => syncQuestion());
    mount.signal.addEventListener("abort", stop, { once: true });
  }
  // The open comes after the views, because its snapshot can show a question.
  if (session !== undefined) opening = open(session);

  /** The waiting messages of the user, oldest first. An input of a plugin stays out of the strip and of a recall. */
  const waiting = (): [InputId, Frozen<Input>][] =>
    [...transcript.pending]
      .filter((entry) => entry[1].source.kind === "user" && entry[1].kind === "message")
      .sort((a, b) => a[0] - b[0]);

  /**
   * The message that ↑ recalls. An empty composer recalls the newest one. After a recall, ↑ recalls the next older one,
   * also after a recall that came too late.
   */
  const recallable = (): [InputId, Frozen<Input>] | undefined => {
    const before = recalled;
    // A browse starts only when no message is recallable, and new messages wait after the recalled one.
    if (before === undefined && composer.state.text !== "") return undefined;
    return waiting().findLast((entry) => before === undefined || entry[0] < before);
  };

  /** Take the waiting message `id` back into the composer, above its text. A message that a turn took stays sent. */
  const recall = async (id: InputId, input: Frozen<Input>): Promise<void> => {
    const target = handle;
    if (target === undefined) return;
    recalling = true;
    recalled = id;
    try {
      const removed = await target.removeInput(id);
      if (mount.signal.aborted) return;
      if (removed) composer.reset(joined(draftOf(input.content), composer.state));
      else ctx.notify("info", "the message reached the turn already");
    } catch (error) {
      if (!mount.signal.aborted) ctx.notify("error", `the message did not come back: ${String(error)}`);
    } finally {
      recalling = false;
    }
  };

  /** Show an older (-1) or a newer (1) message of the user, or the empty composer after the newest one. */
  const browseBy = (step: -1 | 1): void => {
    // The messages of the user in the transcript, oldest first.
    const list = transcript.entries.filter(
      (entry): entry is Extract<Entry, { kind: "input" }> =>
        entry.kind === "input" && entry.source.kind === "user" && entry.inputKind === "message",
    );
    const at = browse === undefined ? list.length : list.findIndex((entry) => entry.key === browse);
    const next = list[at + step];
    if (next === undefined) {
      if (step === 1 && browse !== undefined) {
        composer.reset(EMPTY);
        browse = undefined;
      } else if (step === -1) void load();
      return;
    }
    browse = next.key;
    composer.reset(draftOf(next.content));
  };

  // The layout keeps the row of the rule and the shown waiting messages for the draw. Without a free row, the pane
  // draws no rule.
  let ruleRow = -1;
  let shown: [InputId, Frozen<Input>][] = [];
  const pane: View = {
    contexts: ["chat"],
    layout(size: Size): readonly Placement[] {
      if (dirty) {
        dirty = false;
        view.setDocument(document.project(transcript));
      }
      // A question in the composer place hides the composer, and the composer keeps its draft.
      const question = asking !== undefined && chat.questions === "composer" ? asking.asked : undefined;
      // The composer keeps one row in a pane of any size, and at most half of a taller pane.
      const wanted = question?.rows ?? composer.heightFor(size.width);
      const composerRows = Math.min(wanted, Math.max(1, Math.floor(size.height / 2)));
      const composerRow = Math.max(0, size.height - composerRows);
      ruleRow = composerRow - 1;
      // The strip takes the rows above the rule that its messages need, and the transcript gets the rest. When rows run
      // out, the strip keeps the newest messages.
      const list = waiting();
      shown = list.slice(Math.max(0, list.length - Math.max(0, ruleRow)));
      const placements = [
        { view, rect: { column: 0, row: 0, width: size.width, height: Math.max(0, ruleRow - shown.length) } },
        {
          view: question?.view ?? composer,
          rect: { column: 0, row: composerRow, width: size.width, height: size.height - composerRow },
        },
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
      for (const [at, entry] of shown.entries()) {
        const row = ruleRow - shown.length + at;
        const hint = at === shown.length - 1 ? " ↑ edit" : "";
        const text = inputText(entry[1].content).replaceAll("\n", " ");
        const room = Math.max(0, canvas.width - 1 - measure(hint));
        const cut = fit(text, room) === text.length ? text : `${text.slice(0, fit(text, room - 1))}…`;
        canvas.text(1, row, cut, STYLE.meta);
        if (hint !== "") canvas.text(canvas.width - measure(hint), row, hint, STYLE.hint);
      }
      canvas.text(0, ruleRow, "─".repeat(canvas.width), RULE);
      // The rule shows a failed history load, so the text stays in sight at any scroll place.
      if (historyError !== undefined) canvas.text(1, ruleRow, ` ${historyError} `, STYLE.error);
      else if (view.scroll.state.changedBelow) canvas.text(1, ruleRow, " new output ↓ ", STYLE.hint);
    },
    get initialFocus(): View {
      return asking !== undefined && chat.questions === "composer" ? asking.asked.focus : composer;
    },
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
    status: () => ({ settings: transcript.settings, usage: transcript.usage, jobs: handle?.jobs().length ?? 0 }),
    toggleTools: () => {
      document.toggleTools(transcript);
      changed();
    },
    send: () => void send(),
    chooseModel: () => void chooseModel(),
    pasteImage: () => void pasteImage(),
    browsing: () => browse !== undefined,
    // A waiting recall keeps ↑, so the key does not move the caret meanwhile.
    canOlder: () => recalling || browse !== undefined || composer.state.text === "" || recallable() !== undefined,
    older: () => {
      if (recalling) return;
      const next = recallable();
      if (next !== undefined) void recall(next[0], next[1]);
      else if (browse !== undefined || composer.state.text === "") browseBy(-1);
    },
    newer: () => browseBy(1),
    clear: () => {
      if (composer.state.text === "") handle?.cancel();
      else {
        composer.reset(EMPTY);
        browse = undefined;
        recalled = undefined;
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
      const input = asking !== undefined && chat.questions === "composer" ? asking.asked.focus : composer;
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
    asking: () => asking !== undefined,
    cancelQuestion: () => answer({ kind: "canceled" }),
  });
  return pane;
}
