/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript, composer,
 * folds, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session,
 * the draft, the folds, and the scroll place of each pane. Each command acts on the active pane. The service `chat`
 * shows a session in a pane for other plugins.
 */

import type { ChatPane, ChatPresentation, ChatPresentationOptions, ChatReadOnly, ComposerFrame } from "yuke:chat";
import { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { emptyHeader } from "yuke:internal/bundled/chat/empty";
import {
  type Chat,
  type ComposerViewEntry,
  chatPane,
  type PaneActions,
  type PaneState,
} from "yuke:internal/bundled/chat/pane";
import { clipped } from "yuke:internal/chat/rows";
import type { Frozen, PluginContext } from "yuke:plugins";
import { env } from "yuke:process";
import type { ModelInfo, SessionId, SessionSettings } from "yuke:protocol";
import type { Infer } from "yuke:tools";
import type { Mount, View } from "yuke:tui";

/** The cells of the gauge of the token share of the last answer. */
const GAUGE = 6;

/** The commands of the chat: the name, the description, the keys, their context, and the action. Each action uses the active pane. */
const COMMANDS: readonly {
  readonly slash?: string;
  readonly name: string;
  readonly description: string;
  readonly keys: readonly string[];
  readonly in: "chat" | "composer" | "question";
  readonly run: (pane: PaneActions) => void | Promise<void>;
  readonly enabled?: (pane: PaneActions) => boolean;
}[] = [
  {
    name: "send",
    description: "Send the message",
    keys: ["enter"],
    in: "composer",
    run: (pane) => pane.send(),
    enabled: (pane) => !pane.asking(),
  },
  {
    name: "older-message",
    description: "Edit a waiting message of yours, or show an older message of yours",
    keys: ["up"],
    in: "composer",
    run: (pane) => pane.olderMessage(),
    enabled: (pane) => !pane.asking() && pane.canOlderMessage(),
  },
  {
    name: "newer-message",
    description: "Show a newer message of yours",
    keys: ["down"],
    in: "composer",
    run: (pane) => pane.newerMessage(),
    enabled: (pane) => !pane.asking() && pane.browsing(),
  },
  {
    name: "clear",
    description: "Clear the draft, or stop the turn",
    keys: ["ctrl+c"],
    in: "chat",
    run: (pane) => pane.clear(),
    enabled: (pane) => !pane.locked(),
  },
  {
    name: "background",
    description: "Move the waiting tool calls to the background",
    keys: ["ctrl+b"],
    in: "chat",
    run: (pane) => pane.moveJobsToBackground(),
    enabled: (pane) => !pane.locked(),
  },
  {
    name: "interrupt",
    description: "Drop the selection, or stop the turn",
    keys: ["esc"],
    in: "chat",
    run: (pane) => pane.interrupt(),
  },
  {
    name: "model",
    slash: "model",
    description: "Choose the model and the reasoning",
    keys: ["ctrl+k m"],
    in: "chat",
    run: (pane) => pane.chooseModel(),
    enabled: (pane) => !pane.asking(),
  },
  {
    name: "rename",
    slash: "rename",
    description: "Rename the session",
    keys: [],
    in: "chat",
    run: (pane) => pane.rename(),
    enabled: (pane) => pane.canRename(),
  },
  {
    name: "paste-image",
    description: "Put the image of the clipboard in the message",
    keys: ["ctrl+v"],
    in: "composer",
    run: (pane) => pane.pasteImage(),
    enabled: (pane) => !pane.asking(),
  },
  {
    name: "toggle-tools",
    description: "Open or fold the tools",
    keys: ["ctrl+o"],
    in: "chat",
    run: (pane) => pane.toggleTools(),
  },
  {
    name: "page-up",
    description: "Scroll up one page",
    keys: ["page_up"],
    in: "chat",
    run: (pane) => pane.scroll("pageUp"),
  },
  {
    name: "page-down",
    description: "Scroll down one page",
    keys: ["page_down"],
    in: "chat",
    run: (pane) => pane.scroll("pageDown"),
  },
  { name: "top", description: "Scroll to the top", keys: ["ctrl+home"], in: "chat", run: (pane) => pane.scroll("top") },
  {
    name: "bottom",
    description: "Scroll to the bottom",
    keys: ["ctrl+end"],
    in: "chat",
    run: (pane) => pane.scroll("bottom"),
  },
  {
    name: "cancel-question",
    description: "Cancel the question of a plugin",
    keys: ["esc", "ctrl+c"],
    in: "question",
    run: (pane) => pane.cancelQuestion(),
    enabled: (pane) => pane.asking() && !pane.locked(),
  },
];

export const optionsSchema = {
  type: "object",
  properties: {
    emptyView: {
      type: "boolean",
      description: "Show the header in an empty chat pane. Terminal.app omits the icon. The default is true.",
    },
  },
} as const;

type Options = Infer<typeof optionsSchema>;

export async function apply(ctx: PluginContext<Options>): Promise<void> {
  const tui = ctx.get("tui");
  const listeners = new Set<(view: View) => void>();
  // A disposer can run after this plugin stops, and a stopped `tui` throws.
  const repaint = (): void => {
    if (!ctx.signal.aborted) tui?.requestFrame();
  };
  // One entry per call of `addComposerView`, so each disposer removes its own.
  const composerViews = new Set<ComposerViewEntry>();
  const panes = new Map<View, PaneActions>();
  let presenter: ((options: ChatPresentationOptions) => ChatPresentation) | undefined;
  // One entry per call of `addReadOnly`, so each disposer removes its own.
  const readOnlySources = new Set<{ readonly source: (session: SessionId) => ChatReadOnly | undefined }>();
  let frame: ComposerFrame | undefined;
  // The default view of an empty pane comes after the state that it reads, and the option can turn it off.
  let defaultEmptyView: ((mount: Mount, pane: ChatPane) => View) | undefined;
  let emptyView: ((mount: Mount, pane: ChatPane) => View) | undefined;
  ctx.provide("chat", {
    show: async (id) => {
      if (tui === undefined) throw new Error("no chat pane: yuke runs without the terminal interface");
      const pane = active();
      if (pane !== undefined) return pane.show(id);
      // A focused pane of another plugin keeps its place, and a new chat pane shows the session. A failed open closes
      // the new pane again.
      const created = tui.panes.split((mount) => chatPane(chat, mount, {}));
      try {
        const actions = panes.get(created.view);
        if (actions === undefined) throw new Error("the new chat pane did not open");
        await actions.show(id);
      } catch (error) {
        created.close();
        throw error;
      }
    },
    session: (view) => panes.get(view)?.session(),
    onChange: (listener) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
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
    addReadOnly: (source) => {
      const entry = { source };
      readOnlySources.add(entry);
      repaint();
      return () => {
        if (readOnlySources.delete(entry)) repaint();
      };
    },
    setComposerFrame: (next) => {
      frame = next;
      repaint();
      return () => {
        if (frame !== next) return;
        frame = undefined;
        repaint();
      };
    },
    setPresentation: (factory) => {
      presenter = factory;
      repaint();
      return () => {
        if (presenter !== factory) return;
        presenter = undefined;
        repaint();
      };
    },
    setEmptyView: (create) => {
      emptyView = create;
      repaint();
      return () => {
        if (emptyView !== create) return;
        emptyView = defaultEmptyView;
        repaint();
      };
    },
  });
  if (tui === undefined) return undefined;
  // The work of each open session that a quit stops, also of a session that no pane shows.
  const work = new Map<SessionId, { readonly parent: SessionId | null; turn: boolean; readonly jobs: Set<string> }>();
  ctx.on("session.opened", (data) => {
    const jobs = new Set(data.jobs.map((job) => job.id));
    work.set(data.sessionId, { parent: data.parent, turn: data.state === "running", jobs });
  });
  ctx.on("session.update", ({ sessionId, update }) => {
    const entry = work.get(sessionId);
    if (entry === undefined) return;
    if (update.sessionUpdate === "state") entry.turn = update.state === "running";
    else if (update.sessionUpdate === "job" && update.job.state === "running") entry.jobs.add(update.job.id);
    else if (update.sessionUpdate === "job") entry.jobs.delete(update.job.id);
  });
  ctx.on("session.closed", ({ sessionId }) => work.delete(sessionId));
  const chat: Chat = {
    ctx,
    tui,
    panes,
    refresh: () => publish(),
    choice: await SavedChoice.load(ctx.dataDir, (error) => {
      if (!ctx.signal.aborted) ctx.notify("error", `the model choice did not load: ${String(error)}`);
    }),
    presenter: () => presenter,
    frame: () => frame,
    emptyView: () => emptyView,
    readOnly: (session) => {
      for (const entry of readOnlySources) {
        const answer = entry.source(session);
        if (answer !== undefined) return answer;
      }
      return undefined;
    },
    composerViews: (place) => [...composerViews].filter((entry) => entry.place === place),
    moved: (view) => {
      for (const listener of listeners) listener(view);
    },
  };
  const active = (): PaneActions | undefined => {
    const view = tui.panes.active?.view;
    return view === undefined ? undefined : chat.panes.get(view);
  };
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
  // Activation finishes the read before any pane can use the state.
  await readModels();
  /** The open question before a quit. */
  let asked: Mount | undefined;
  const home = env.get("HOME");
  /** `folder` with the home folder as `~`. */
  const shownFolder = (folder: string): string =>
    home !== undefined && (folder === home || folder.startsWith(`${home}/`)) ? `~${folder.slice(home.length)}` : folder;
  /**
   * The model with its level, and the folder, of the next message of a pane. A pane without a session uses the saved
   * pick, while its provider is ready, and the start folder. A session without its settings yet gives nothing.
   */
  const targetOf = (
    bound: boolean,
    settings: Frozen<SessionSettings> | undefined,
  ): { readonly model?: string | undefined; readonly folder?: string | undefined } => {
    if (bound) {
      if (settings === undefined) return {};
      const { thinking, effort } = settings.settings.reasoning;
      const level = models
        ?.get(`${settings.model.provider}/${settings.model.model}`)
        ?.reasoning.find(
          (choice) =>
            choice.settings.effort === effort && JSON.stringify(choice.settings.thinking) === JSON.stringify(thinking),
        )?.level;
      const model = level === undefined ? settings.model.model : `${settings.model.model} ${level}`;
      return { model, folder: shownFolder(settings.cwd) };
    }
    const pick = chat.choice.current;
    const level = models
      ?.get(`${pick?.model.provider}/${pick?.model.model}`)
      ?.reasoning.find((choice) => choice.level === pick?.reasoning)?.level;
    const model = pick === undefined || level === undefined ? undefined : `${pick.model.model} ${level}`;
    return { model, folder: shownFolder(tui.startup.cwd) };
  };
  /** Show the folder item with `text`, or no folder item. */
  const setFolder = (text: string | undefined): void => {
    // The folder gives way first in a narrow bar.
    if (text === undefined) tui.status.delete("folder");
    else tui.status.set("folder", { text, side: "left", order: 10, priority: -1 });
  };
  /** Show the model item with `text`, or no model item. */
  const setModel = (text: string | undefined): void => {
    if (text === undefined) tui.status.delete("model");
    else tui.status.set("model", { text, side: "right", order: 10 });
  };
  /**
   * Show the folder, the model, the token share of the last answer, and the process jobs of the focused chat pane, or
   * nothing.
   */
  const publish = (): void => {
    // A handle can end after the stop of the plugin, when its tui takes no more calls.
    if (ctx.signal.aborted) return;
    const status = active()?.status();
    const target = status === undefined ? {} : targetOf(status.bound, status.settings);
    setFolder(target.folder);
    setModel(target.model);
    const settings = status?.settings;
    if (status === undefined || settings === undefined) {
      for (const key of ["context", "jobs"]) tui.status.delete(key);
      return;
    }
    const model = models?.get(`${settings.model.provider}/${settings.model.model}`);
    const usage = status.usage;
    // A count that the provider did not send is unknown, not zero.
    if (usage === undefined || usage.input === null) tui.status.delete("context");
    else {
      const used = usage.input + (usage.output ?? 0);
      const window = model?.contextWindow ?? undefined;
      const share = window === undefined ? undefined : Math.min(1, used / window);
      const text =
        share === undefined
          ? `${(used / 1000).toFixed(1)}k tokens`
          : `${"▰".repeat(Math.round(share * GAUGE))}${"▱".repeat(GAUGE - Math.round(share * GAUGE))} ${Math.round(share * 100)}%`;
      tui.status.set("context", { text, side: "right", order: 20, priority: 1 });
    }
    if (status.jobs === 0) tui.status.delete("jobs");
    else tui.status.set("jobs", { text: `jobs ${status.jobs}`, side: "right", order: 1, priority: 2 });
  };
  defaultEmptyView =
    ctx.options.emptyView === false
      ? undefined
      : (_mount, pane) =>
          emptyHeader({
            version: tui.startup.version,
            target: () => targetOf(pane.session !== undefined, pane.transcript.settings),
            // Without the catalog, the header keeps the usual hint.
            ready: () => models === undefined || models.size > 0,
            // Terminal.app finds no font with sextant glyphs and draws boxes.
            icon: env.get("TERM_PROGRAM") !== "Apple_Terminal",
          });
  // A plugin can set its view before the default exists.
  emptyView ??= defaultEmptyView;
  tui.onFocusChange(() => publish());
  ctx.on("catalog.changed", () => {
    // The bar and the header of an empty pane name the models of the ready providers.
    void readModels().then(() => {
      publish();
      repaint();
    });
  });
  tui.guardQuit((quit) => {
    // The resume text names each shown session, and each session whose work the quit stops.
    const resumed = new Set([...panes.values()].flatMap((pane) => pane.resumeSession() ?? []));
    let turns = 0;
    let jobs = 0;
    for (const [session, entry] of work) {
      // A subagent runs as a job of its parent, so the turn of a child session does not count again.
      const turn = entry.turn && entry.parent === null;
      turns += turn ? 1 : 0;
      jobs += entry.jobs.size;
      // A child session resumes at its parent.
      if (turn || entry.jobs.size > 0) resumed.add(entry.parent ?? session);
    }
    // The host writes this text after it restores the terminal, so the user can open each session again.
    const resume = [...resumed].map((session) => `To resume this session, run: yuke -r ${session}`).join("\n");
    const leave = (): void => quit(resume === "" ? undefined : resume);
    if (asked !== undefined || turns + jobs === 0) {
      leave();
      return;
    }
    const counts = [
      ...(turns === 0 ? [] : [`${turns} ${turns === 1 ? "turn" : "turns"}`]),
      ...(jobs === 0 ? [] : [`${jobs} ${jobs === 1 ? "job" : "jobs"}`]),
    ];
    const text = `${counts.join(" and ")} ${turns + jobs === 1 ? "is" : "are"} running.`;
    const stay = (): void => asked?.close();
    asked = tui.dialog({
      title: () => "Stop everything and quit?",
      body: { draw: (canvas) => canvas.text(1, 0, clipped(text, Math.max(0, canvas.width - 1))) },
      keys: [
        { key: "enter", label: "stop and quit", run: leave },
        { key: "ctrl+q", label: "stop and quit", run: leave },
        { key: "esc", label: "stay", run: stay },
      ],
      rows: 3,
    });
    asked.signal.addEventListener("abort", () => {
      asked = undefined;
    });
  });
  tui.views.register("pane", (state, mount) => chatPane(chat, mount, state as PaneState));
  tui.panes.setDefault((mount, reason) =>
    chatPane(chat, mount, { session: reason === "start" ? tui.startup.session : undefined }),
  );
  for (const command of COMMANDS) {
    tui.commands.add({
      name: command.name,
      slash: command.slash,
      description: command.description,
      run: () => {
        const pane = active();
        return pane === undefined ? undefined : command.run(pane);
      },
      // A command of the chat runs only in a chat pane, so a list of commands in another pane leaves it out.
      enabled: () => {
        const pane = active();
        return pane !== undefined && (command.enabled?.(pane) ?? true);
      },
    });
    for (const key of command.keys) tui.keys.bind(key, command.name, { in: command.in });
  }
  return undefined;
}
