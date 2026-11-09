/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript, composer,
 * folds, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session,
 * the draft, the folds, and the scroll place of each pane. Each command acts on the active pane. The service `chat`
 * shows a session in a pane for other plugins.
 */

import type { ChatPresentation, ChatPresentationOptions, ChatReadOnly, ComposerFrame } from "yuke:chat";
import { SavedChoice } from "yuke:internal/bundled/chat/choice";
import {
  type Chat,
  type ComposerViewEntry,
  chatPane,
  type PaneActions,
  type PaneState,
} from "yuke:internal/bundled/chat/pane";
import { clipped } from "yuke:internal/chat/rows";
import type { PluginContext } from "yuke:plugins";
import type { ModelInfo, SessionId } from "yuke:protocol";
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

export async function apply(ctx: PluginContext): Promise<void> {
  const tui = ctx.get("tui");
  const listeners = new Set<(view: View) => void>();
  // A disposer can run after this plugin stops, and a stopped `tui` throws.
  const repaint = (): void => {
    if (!ctx.signal.aborted) tui?.requestFrame();
  };
  // One entry per call of `addComposerView`, so each disposer removes its own.
  const composerViews = new Set<ComposerViewEntry>();
  const panes = new WeakMap<View, PaneActions>();
  const open = new Set<PaneActions>();
  let presenter: ((options: ChatPresentationOptions) => ChatPresentation) | undefined;
  // One entry per call of `addReadOnly`, so each disposer removes its own.
  const readOnlySources = new Set<{ readonly source: (session: SessionId) => ChatReadOnly | undefined }>();
  let frame: ComposerFrame | undefined;
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
  });
  if (tui === undefined) return undefined;
  const runningSessions = new Set<SessionId>();
  ctx.on("session.opened", ({ sessionId, state }) => {
    if (state === "running") runningSessions.add(sessionId);
  });
  ctx.on("session.update", ({ sessionId, update }) => {
    if (update.sessionUpdate !== "state") return;
    if (update.state === "running") runningSessions.add(sessionId);
    else runningSessions.delete(sessionId);
  });
  ctx.on("session.closed", ({ sessionId }) => runningSessions.delete(sessionId));
  const chat: Chat = {
    ctx,
    tui,
    panes,
    refresh: () => publish(),
    refreshModels: () => {
      void readModels().then(publish);
    },
    choice: await SavedChoice.load(ctx.dataDir, (error) => {
      if (!ctx.signal.aborted) ctx.notify("error", `the model choice did not load: ${String(error)}`);
    }),
    open,
    presenter: () => presenter,
    frame: () => frame,
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
  // A session can use a provider that is not ready now, so the list holds each provider.
  let models: Map<string, ModelInfo> | undefined;
  let ready: ReadonlySet<string> = new Set();
  const readModels = (): Promise<void> =>
    ctx
      .get("catalog")
      .list({ all: true })
      .then(
        (catalog) => {
          const providers = catalog.providers;
          models = new Map(
            providers.flatMap((provider) => provider.models.map((model) => [`${provider.id}/${model.id}`, model])),
          );
          ready = new Set(
            providers.filter((provider) => provider.state.kind === "ready").map((provider) => provider.id),
          );
        },
        // Without the catalog, the model item has no level, and the context item is a token count.
        () => {
          models = undefined;
          ready = new Set();
        },
      );
  // Activation finishes the read before any pane can use the state.
  await readModels();
  /** Show the model, the token share of the last answer, and the process jobs of the focused chat pane, or nothing. */
  /** The open question before a quit. */
  let asked: Mount | undefined;
  const publish = (): void => {
    // A handle can end after the stop of the plugin, when its tui takes no more calls.
    if (ctx.signal.aborted) return;
    const status = active()?.status();
    const settings = status?.settings;
    if (status === undefined || settings === undefined) {
      for (const key of ["context", "jobs"]) tui.status.delete(key);
      // A pane without a session shows the saved pick that its first send uses, while its provider is ready.
      const saved = status === undefined || status.bound ? undefined : chat.choice.current;
      const pick = saved !== undefined && ready.has(saved.model.provider) ? saved : undefined;
      const level = models
        ?.get(`${pick?.model.provider}/${pick?.model.model}`)
        ?.reasoning.find((choice) => choice.level === pick?.reasoning)?.level;
      if (pick === undefined || level === undefined) tui.status.delete("model");
      else tui.status.set("model", { text: `${pick.model.model} ${level}`, side: "right", order: 10 });
      return;
    }
    const model = models?.get(`${settings.model.provider}/${settings.model.model}`);
    const { thinking, effort } = settings.settings.reasoning;
    const level = model?.reasoning.find(
      (choice) =>
        choice.settings.effort === effort && JSON.stringify(choice.settings.thinking) === JSON.stringify(thinking),
    )?.level;
    const name = level === undefined ? settings.model.model : `${settings.model.model} ${level}`;
    tui.status.set("model", { text: name, side: "right", order: 10 });
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
  tui.onFocusChange(() => publish());
  tui.guardQuit((quit) => {
    // Two panes on one session count once.
    const work = new Map(
      [...open].flatMap((pane) => {
        const entry = pane.work();
        return entry === undefined ? [] : [[entry.session, entry] as const];
      }),
    );
    // A read-only pane resumes at its parent, and the parent can have no pane, so its turn counts here.
    const resumed = new Set([...work.values()].map((entry) => entry.resume));
    const running = new Set([...work.values()].filter((entry) => entry.turn).map((entry) => entry.session));
    for (const session of resumed) if (runningSessions.has(session)) running.add(session);
    const turns = running.size;
    const jobs = [...work.values()].reduce((count, entry) => count + entry.jobs, 0);
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
