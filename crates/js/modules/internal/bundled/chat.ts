/**
 * The bundled plugin `chat`: the main view of the terminal interface. It shows one session tree: a root session, and
 * its child sessions read-only. It starts on the session of `tui.startup`, and `/new` empties it. A switch to another
 * root, `/new`, and a quit ask before they stop the work of the tree, and the old root closes. A reload keeps the root,
 * the draft, the folds, the scroll place, and the folder of the next root. The service `chat` shows a session for other
 * plugins.
 */

import type { ChatPresentation, ChatPresentationOptions, ChatView, CompletionProvider, ComposerFrame } from "yuke:chat";
import { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { emptyHeader } from "yuke:internal/bundled/chat/empty";
import {
  type Chat,
  type ChatActions,
  type ComposerViewEntry,
  chatView,
  type SavedChat,
} from "yuke:internal/bundled/chat/view";
import { slashCompletions } from "yuke:internal/chat/commands";
import { clipped } from "yuke:internal/chat/rows";
import { failureOf } from "yuke:internal/failure";
import { Listeners } from "yuke:internal/listeners";
import { Stack } from "yuke:internal/stack";
import type { PluginContext } from "yuke:plugins";
import { env } from "yuke:process";
import type { ModelInfo, SessionId } from "yuke:protocol";
import type { Infer } from "yuke:tools";
import type { Mount, StatusEntry, View } from "yuke:tui";

/** The cells of the gauge of the token share of the last answer. */
const GAUGE = 6;

/** The commands of the chat: the name, the description, the keys, their context, and the action. */
const COMMANDS: readonly {
  readonly slash?: string;
  readonly name: string;
  readonly description: string;
  readonly keys: readonly string[];
  readonly in: "chat" | "composer" | "question";
  readonly run: (chat: ChatActions) => void | Promise<void>;
  readonly enabled?: (chat: ChatActions) => boolean;
}[] = [
  {
    name: "send",
    description: "Send the message",
    keys: ["enter"],
    in: "composer",
    run: (chat) => chat.send(),
    enabled: (chat) => chat.composing(),
  },
  {
    name: "older-message",
    description: "Edit a waiting message of yours, or show an older message of yours",
    keys: ["up"],
    in: "composer",
    run: (chat) => chat.olderMessage(),
    enabled: (chat) => chat.composing() && chat.canOlderMessage(),
  },
  {
    name: "newer-message",
    description: "Show a newer message of yours",
    keys: ["down"],
    in: "composer",
    run: (chat) => chat.newerMessage(),
    enabled: (chat) => chat.composing() && chat.browsing(),
  },
  {
    name: "clear",
    description: "Clear the draft, or stop the turn",
    keys: ["ctrl+c"],
    in: "chat",
    run: (chat) => chat.clear(),
    enabled: (chat) => !chat.showsChild(),
  },
  {
    name: "background",
    description: "Move the waiting tool calls to the background",
    keys: ["ctrl+b"],
    in: "chat",
    run: (chat) => chat.moveJobsToBackground(),
    enabled: (chat) => !chat.showsChild(),
  },
  {
    name: "interrupt",
    description: "Drop the selection, go back to the root, or stop the turn",
    keys: ["esc"],
    in: "chat",
    run: (chat) => chat.interrupt(),
  },
  {
    name: "model",
    slash: "model",
    description: "Choose the model and the reasoning",
    keys: ["ctrl+k m"],
    in: "chat",
    run: (chat) => chat.chooseModel(),
    enabled: (chat) => chat.composing(),
  },
  {
    name: "new",
    slash: "new",
    description: "Start a new session",
    keys: ["ctrl+k n"],
    in: "chat",
    run: (chat) => chat.newSession(),
    enabled: (chat) => chat.composing() && chat.view.rootId !== undefined,
  },
  {
    name: "rename",
    slash: "rename",
    description: "Rename the session",
    keys: [],
    in: "chat",
    run: (chat) => chat.rename(),
    enabled: (chat) => chat.canRename(),
  },
  {
    name: "paste-image",
    description: "Put the image of the clipboard in the message",
    keys: ["ctrl+v"],
    in: "composer",
    run: (chat) => chat.pasteImage(),
    enabled: (chat) => chat.composing(),
  },
  {
    name: "toggle-tools",
    description: "Open or fold the tools",
    keys: ["ctrl+o"],
    in: "chat",
    run: (chat) => chat.toggleTools(),
  },
  {
    name: "page-up",
    description: "Scroll up one page",
    keys: ["pageup"],
    in: "chat",
    run: (chat) => chat.scroll("pageUp"),
  },
  {
    name: "page-down",
    description: "Scroll down one page",
    keys: ["pagedown"],
    in: "chat",
    run: (chat) => chat.scroll("pageDown"),
  },
  { name: "top", description: "Scroll to the top", keys: ["ctrl+home"], in: "chat", run: (chat) => chat.scroll("top") },
  {
    name: "bottom",
    description: "Scroll to the bottom",
    keys: ["ctrl+end"],
    in: "chat",
    run: (chat) => chat.scroll("bottom"),
  },
  {
    name: "cancel-question",
    description: "Cancel the question of a plugin",
    keys: ["esc", "ctrl+c"],
    in: "question",
    run: (chat) => chat.cancelQuestion(),
    enabled: (chat) => chat.asking(),
  },
];

export const optionsSchema = {
  type: "object",
  properties: {
    emptyView: {
      type: "boolean",
      description: "Show the header in an empty chat. Terminal.app omits the icon. The default is true.",
    },
  },
} as const;

type Options = Infer<typeof optionsSchema>;

/** One call of `addViewWatcher`. The abort of `stop` ends its watch of each view. */
interface ViewWatcher {
  readonly watch: (view: ChatView, signal: AbortSignal) => void;
  readonly stop: AbortController;
}

export async function apply(ctx: PluginContext<Options>): Promise<void> {
  const tui = ctx.get("tui");
  const listeners = new Listeners<[]>();
  // A disposer can run after this plugin stops, and a stopped `tui` throws.
  const repaint = (): void => {
    if (!ctx.signal.aborted) tui?.requestFrame();
  };
  // A change of a single-slot value repaints now and at its removal.
  const repainted = (remove: () => void): (() => void) => {
    repaint();
    return () => {
      remove();
      repaint();
    };
  };
  // One entry per call of `addComposerView`, so each disposer removes its own.
  const composerViews = new Set<ComposerViewEntry>();
  // The actions of the chat view, while it shows.
  let current: ChatActions | undefined;
  const viewWatchers = new Set<ViewWatcher>();
  const startWatcher = (entry: ViewWatcher, actions: ChatActions): void => {
    // A failed watcher of another plugin must not stop the open of the view.
    try {
      entry.watch(actions.view, AbortSignal.any([actions.signal, entry.stop.signal]));
    } catch (error) {
      ctx.notify("error", `A view watcher failed: ${failureOf(error)}`);
    }
  };
  const presenters = new Stack<(options: ChatPresentationOptions) => ChatPresentation>();
  // One entry per call of `addCompletionProvider`, oldest first, so each disposer removes its own.
  const completionProviders = new Set<{ readonly provider: CompletionProvider }>();
  // One entry per call of `addChildLabel`, so each disposer removes its own.
  const childLabels = new Set<{ readonly source: (session: SessionId) => string | undefined }>();
  const frames = new Stack<ComposerFrame>();
  const emptyViews = new Stack<(mount: Mount, view: ChatView) => View>();
  // The default view of an empty chat comes after the state that it reads, and the option can turn it off.
  let defaultEmptyView: ((mount: Mount, view: ChatView) => View) | undefined;
  ctx.provide("chat", {
    show: async (id) => {
      if (tui === undefined) throw new Error("no chat: yuke runs without the terminal interface");
      if (current === undefined) throw new Error("no chat: another plugin shows the main view");
      return current.show(id);
    },
    sessionId: () => current?.view.sessionId,
    addChangeListener: (listener) => listeners.add(listener),
    addComposerView: (place, create) => {
      const entry = { place, create, stop: new AbortController() };
      composerViews.add(entry);
      repaint();
      return () => {
        if (!composerViews.delete(entry)) return;
        entry.stop.abort();
        repaint();
      };
    },
    addViewWatcher: (watch) => {
      const entry = { watch, stop: new AbortController() };
      viewWatchers.add(entry);
      if (current !== undefined) startWatcher(entry, current);
      return () => {
        if (viewWatchers.delete(entry)) entry.stop.abort();
      };
    },
    addCompletionProvider: (provider) => {
      const entry = { provider };
      completionProviders.add(entry);
      return () => {
        completionProviders.delete(entry);
      };
    },
    addChildLabel: (source) => {
      const entry = { source };
      childLabels.add(entry);
      repaint();
      return () => {
        if (childLabels.delete(entry)) repaint();
      };
    },
    setComposerFrame: (frame) => repainted(frames.add(frame)),
    setPresentation: (factory) => repainted(presenters.add(factory)),
    setEmptyView: (create) => repainted(emptyViews.add(create)),
  });
  if (tui === undefined) return undefined;
  // The work of each open session, from the events of the host. The chat holds only the root and a shown child, but a
  // quit and a switch stop the work of each child of the root.
  const work = new Map<
    SessionId,
    { readonly parent: SessionId | undefined; turn: boolean; readonly jobs: Set<string> }
  >();
  ctx.addListener("session.opened", (data) => {
    const jobs = new Set(data.jobs.map((job) => job.id));
    work.set(data.sessionId, { parent: data.parent, turn: data.state === "running", jobs });
  });
  ctx.addListener("session.update", (data) => {
    const entry = work.get(data.sessionId);
    if (entry === undefined) return;
    if (data.update.kind === "state") entry.turn = data.update.state === "running";
    else if (data.update.kind === "job" && data.update.job.state === "running") entry.jobs.add(data.update.job.id);
    else if (data.update.kind === "job") entry.jobs.delete(data.update.job.id);
  });
  ctx.addListener("session.closed", (data) => work.delete(data.sessionId));
  const chat: Chat = {
    ctx,
    tui,
    refresh: () => publish(),
    choice: await SavedChoice.load(ctx.dataDir, (error) => {
      if (!ctx.signal.aborted) ctx.notify("error", `The model choice did not load: ${String(error)}`);
    }),
    presenter: () => presenters.top(),
    frame: () => frames.top(),
    emptyView: () => emptyViews.top() ?? defaultEmptyView,
    childLabel: (session) => {
      for (const entry of childLabels) {
        const answer = entry.source(session);
        if (answer !== undefined) return answer;
      }
      return undefined;
    },
    confirmStop: (root, kind) => confirmStop(root, kind),
    composerViews: (place) => [...composerViews].filter((entry) => entry.place === place),
    moved: () => listeners.call(),
    opened: (actions) => {
      current = actions;
      actions.signal.addEventListener(
        "abort",
        () => {
          // The core closes the main view before it shows the next one, so the closed view is the current one.
          current = undefined;
          // The bar shows no session of a closed chat.
          publish();
        },
        { once: true },
      );
      for (const entry of viewWatchers) startWatcher(entry, actions);
      publish();
    },
    completionProviders: () => [...completionProviders].map((entry) => entry.provider).toReversed(),
  };
  // The slash commands are the oldest provider, so a plugin can take their place.
  completionProviders.add({ provider: slashCompletions(tui.commands) });
  // The models of the ready providers. A change of the providers reads them again.
  let models: Map<string, ModelInfo> | undefined;
  const readModels = (): Promise<void> =>
    ctx
      .get("catalog")
      .list()
      .then(
        (catalog) => {
          models = new Map(
            catalog.providers.flatMap((provider) =>
              provider.models.map((model) => [`${provider.id}/${model.id}`, model]),
            ),
          );
        },
        // Without the catalog, the model item has no level, and the context item is a token count.
        () => {
          models = undefined;
        },
      );
  // Activation finishes the read before the view can use the state.
  await readModels();
  /** The open confirmation of a stop. */
  let asked: Mount | undefined;
  /** The text of the turn and the jobs that run in the tree of `root`, or `undefined` when nothing runs. */
  const runningIn = (root: SessionId | undefined): string | undefined => {
    if (root === undefined) return undefined;
    let turns = 0;
    let jobs = 0;
    for (const [session, entry] of work) {
      if (session !== root && entry.parent !== root) continue;
      // A subagent runs as a job of its parent, so the turn of a child does not count again.
      if (session === root && entry.turn) turns += 1;
      jobs += entry.jobs.size;
    }
    if (turns + jobs === 0) return undefined;
    const counts = [
      ...(turns === 0 ? [] : [`${turns} ${turns === 1 ? "turn" : "turns"}`]),
      ...(jobs === 0 ? [] : [`${jobs} ${jobs === 1 ? "job" : "jobs"}`]),
    ];
    return `${counts.join(" and ")} ${turns + jobs === 1 ? "is" : "are"} running.`;
  };
  /**
   * Ask whether to stop the work of the tree of `root` before `kind`. Gives `true` at once when nothing runs, and
   * `false` after a stay or while another confirmation shows.
   */
  const confirmStop = (root: SessionId | undefined, kind: "quit" | "switch"): Promise<boolean> => {
    const text = runningIn(root);
    if (text === undefined) return Promise.resolve(true);
    if (asked !== undefined) return Promise.resolve(false);
    const { promise, resolve } = Promise.withResolvers<boolean>();
    const answer = (stop: boolean) => (): void => {
      resolve(stop);
      asked?.close();
    };
    asked = tui.dialog({
      title: kind === "quit" ? "Stop everything and quit?" : "Stop them and switch?",
      body: { draw: (canvas) => canvas.text(1, 0, clipped(text, Math.max(0, canvas.width - 1))) },
      // The quit key quits through the keymap, and its entry names it in the footer.
      keys: [
        { key: "enter", label: `stop and ${kind}`, run: answer(true) },
        ...(kind === "quit" ? [{ key: "ctrl+q", label: "stop and quit", run: answer(true) }] : []),
        { key: "esc", label: "stay", run: answer(false) },
      ],
      rows: 3,
    });
    asked.signal.addEventListener("abort", () => {
      asked = undefined;
      resolve(false);
    });
    return promise;
  };
  const home = env.get("HOME");
  /** `folder` with the home folder as `~`. */
  const shownFolder = (folder: string): string =>
    home !== undefined && (folder === home || folder.startsWith(`${home}/`)) ? `~${folder.slice(home.length)}` : folder;
  /**
   * The model with its level, and the folder, of the next message of the chat with `status`. A chat without a root uses
   * the saved pick, while its provider is ready, and the folder of its next root. A session without its settings yet
   * gives nothing.
   */
  const targetOf = (
    status: ReturnType<ChatActions["status"]>,
  ): { readonly model?: string | undefined; readonly folder?: string | undefined } => {
    const settings = status.settings;
    if (status.bound) {
      if (settings === undefined) return {};
      const { thinking, effort } = settings.settings.reasoning;
      const level = models
        ?.get(`${settings.model.provider}/${settings.model.model}`)
        ?.reasoning.find(
          (choice) =>
            choice.settings.effort === effort && JSON.stringify(choice.settings.thinking) === JSON.stringify(thinking),
        )?.level;
      const model = level === undefined ? settings.model.model : `${settings.model.model} ${level}`;
      return { model, folder: shownFolder(settings.folder) };
    }
    const pick = chat.choice.current;
    const level = models
      ?.get(`${pick?.model.provider}/${pick?.model.model}`)
      ?.reasoning.find((choice) => choice.level === pick?.reasoning)?.level;
    const model = pick === undefined || level === undefined ? undefined : `${pick.model.model} ${level}`;
    return { model, folder: shownFolder(status.nextFolder) };
  };
  // The remover of each shown item. A new `set` of an id replaces the item, so the older remover then does nothing.
  const statusRemovers = new Map<string, () => void>();
  /** Show the item `id` with `entry`, or no item for `undefined`. */
  const showStatus = (id: string, entry: StatusEntry | undefined): void => {
    if (entry === undefined) {
      statusRemovers.get(id)?.();
      statusRemovers.delete(id);
    } else statusRemovers.set(id, tui.status.set(id, entry));
  };
  /** Show the folder item with `text`, or no folder item. */
  const setFolder = (text: string | undefined): void => {
    // The folder gives way first in a narrow bar.
    showStatus("folder", text === undefined ? undefined : { text, side: "left", order: 10, priority: -1 });
  };
  /** Show the model item with `text`, or no model item. */
  const setModel = (text: string | undefined): void => {
    showStatus("model", text === undefined ? undefined : { text, side: "right", order: 10 });
  };
  /** Show the folder, the model, the token share of the last answer, and the process jobs of the shown session. */
  const publish = (): void => {
    // A handle can end after the stop of the plugin, when its tui takes no more calls.
    if (ctx.signal.aborted) return;
    const status = current?.status();
    const target = status === undefined ? {} : targetOf(status);
    setFolder(target.folder);
    setModel(target.model);
    const settings = status?.settings;
    if (status === undefined || settings === undefined) {
      for (const key of ["context", "jobs"]) showStatus(key, undefined);
      return;
    }
    const model = models?.get(`${settings.model.provider}/${settings.model.model}`);
    const usage = status.usage;
    // A count that the provider did not send is unknown, not zero.
    if (usage?.input === undefined) showStatus("context", undefined);
    else {
      const used = usage.input + (usage.output ?? 0);
      const window = model?.contextWindow;
      const share = window === undefined ? undefined : Math.min(1, used / window);
      const text =
        share === undefined
          ? `${(used / 1000).toFixed(1)}k tokens`
          : `${"▰".repeat(Math.round(share * GAUGE))}${"▱".repeat(GAUGE - Math.round(share * GAUGE))} ${Math.round(share * 100)}%`;
      showStatus("context", { text, side: "right", order: 20, priority: 1 });
    }
    showStatus(
      "jobs",
      status.jobs === 0 ? undefined : { text: `Jobs ${status.jobs}`, side: "right", order: 1, priority: 2 },
    );
  };
  defaultEmptyView =
    ctx.options.emptyView === false
      ? undefined
      : () =>
          emptyHeader({
            version: tui.startup.version,
            target: () => {
              const status = current?.status();
              return status === undefined ? {} : targetOf(status);
            },
            // Without the catalog, the header keeps the usual hint.
            ready: () => models === undefined || models.size > 0,
            // Terminal.app finds no font with sextant glyphs and draws boxes.
            icon: env.get("TERM_PROGRAM") !== "Apple_Terminal",
          });
  ctx.addListener("catalog.changed", () => {
    // The bar and the header of an empty chat name the models of the ready providers.
    void readModels().then(() => {
      publish();
      repaint();
    });
  });
  tui.addQuitGuard((quit) => {
    const root = current?.view.rootId;
    // The host writes this text after it restores the terminal, so the user can open the root again.
    const resume = root === undefined ? undefined : `To resume this session, run: yuke -r ${root}`;
    // A quit with no work goes at once, and a second quit key during a confirmation quits.
    if (asked !== undefined || runningIn(root) === undefined) {
      quit(resume);
      return;
    }
    void confirmStop(root, "quit").then((stop) => {
      if (stop) quit(resume);
    });
  });
  // A saved chat of a reload keeps its root, and a new chat shows the session of the start.
  tui.setMain((mount, saved) =>
    chatView(chat, mount, saved === null ? { session: tui.startup.sessionId } : (saved as SavedChat)),
  );
  for (const command of COMMANDS) {
    tui.commands.add({
      name: command.name,
      slash: command.slash,
      description: command.description,
      // A command of the chat is enabled only while the chat shows, and a disabled command does not run.
      run: () => command.run(current as ChatActions),
      enabled: () => current !== undefined && (command.enabled?.(current) ?? true),
    });
    for (const key of command.keys) tui.keys.add(key, command.name, { in: command.in });
  }
  return undefined;
}
