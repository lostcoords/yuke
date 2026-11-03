/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript, composer,
 * folds, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session,
 * the draft, the folds, and the scroll place of each pane. Each command acts on the active pane. The service `chat`
 * shows a session in a pane for other plugins.
 */

import type {
  ChatPresentation,
  ChatPresentationOptions,
  ChatReadOnly,
  ComposerRow,
  ComposerRowPlace,
  ComposerRowsContext,
} from "yuke:chat";
import { SavedChoice } from "yuke:internal/bundled/chat/choice";
import { type Chat, chatPane, type PaneActions, type PaneState } from "yuke:internal/bundled/chat/pane";
import { clipped } from "yuke:internal/chat/rows";
import type { PluginContext } from "yuke:plugins";
import type { ModelInfo, SessionId } from "yuke:protocol";
import type { Mount, View } from "yuke:tui";

/** The cells of the gauge of the token share of the last answer. */
const GAUGE = 6;

/** The commands of the chat: the name, the description, the keys, their context, and the action. Each action uses the active pane. */
const COMMANDS: readonly {
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
    run: (pane) => pane.older(),
    enabled: (pane) => !pane.asking() && pane.canOlder(),
  },
  {
    name: "newer-message",
    description: "Show a newer message of yours",
    keys: ["down"],
    in: "composer",
    run: (pane) => pane.newer(),
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
    run: (pane) => pane.moveToBackground(),
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
    description: "Choose the model and the reasoning",
    keys: ["ctrl+k m"],
    in: "chat",
    run: (pane) => pane.chooseModel(),
    enabled: (pane) => !pane.asking(),
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
    enabled: (pane) => pane.asking(),
  },
];

export async function apply(ctx: PluginContext): Promise<void> {
  const tui = ctx.get("tui");
  const listeners = new Set<(view: View) => void>();
  // One entry per call of `addComposerRows`, so the same source can show twice and each disposer removes its own.
  const sources = new Set<{
    readonly place: ComposerRowPlace;
    readonly source: (pane: ComposerRowsContext) => readonly ComposerRow[];
  }>();
  const panes = new WeakMap<View, PaneActions>();
  const open = new Set<PaneActions>();
  let presenter: ((options: ChatPresentationOptions) => ChatPresentation) | undefined;
  let readOnly: ((session: SessionId) => ChatReadOnly | undefined) | undefined;
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
    addComposerRows: (place, source) => {
      const entry = { place, source };
      sources.add(entry);
      tui?.requestFrame();
      return () => {
        if (sources.delete(entry)) tui?.requestFrame();
      };
    },
    setReadOnly: (source) => {
      readOnly = source;
      tui?.requestFrame();
      return () => {
        if (readOnly !== source) return;
        readOnly = undefined;
        tui?.requestFrame();
      };
    },
    present: (factory) => {
      presenter = factory;
      tui?.requestFrame();
      return () => {
        if (presenter !== factory) return;
        presenter = undefined;
        tui?.requestFrame();
      };
    },
  });
  if (tui === undefined) return undefined;
  const chat: Chat = {
    ctx,
    tui,
    panes,
    refresh: () => publish(),
    choice: await SavedChoice.load(ctx.dataDir, (error) => {
      if (!ctx.signal.aborted) ctx.notify("error", `the model choice did not load: ${String(error)}`);
    }),
    open,
    presenter: () => presenter,
    readOnly: (session) => readOnly?.(session),
    rows: (place, pane, room) => {
      const rows: ComposerRow[] = [];
      for (const entry of sources) {
        if (entry.place !== place) continue;
        const added = entry.source(pane);
        if (rows.length + added.length > room) break;
        rows.push(...added);
      }
      return rows;
    },
    moved: (view) => {
      for (const listener of listeners) listener(view);
    },
  };
  const active = (): PaneActions | undefined => {
    const view = tui.panes.active?.view;
    return view === undefined ? undefined : chat.panes.get(view);
  };
  // Activation finishes the reads before any pane can use their state.
  const models = await ctx
    .get("catalog")
    .list()
    .then(
      (catalog) =>
        new Map<string, ModelInfo>(
          catalog.providers.flatMap((provider) =>
            provider.models.map((model) => [`${provider.id}/${model.id}`, model]),
          ),
        ),
      // Without the catalog, the model item has no level, and the context item is a token count.
      () => undefined,
    );
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
      // A pane without a session shows the saved pick that its first send uses, while the catalog still has it.
      const pick = status === undefined || status.bound ? undefined : chat.choice.current;
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
  tui.onFocus(() => publish());
  tui.guardQuit((quit) => {
    // Two panes on one session count once.
    const work = new Map(
      [...open].flatMap((pane) => {
        const entry = pane.work();
        return entry === undefined ? [] : [[entry.session, entry] as const];
      }),
    );
    const turns = [...work.values()].filter((entry) => entry.turn).length;
    const jobs = [...work.values()].reduce((count, entry) => count + entry.jobs, 0);
    if (asked !== undefined || turns + jobs === 0) {
      quit();
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
        { key: "enter", label: "stop and quit", run: quit },
        { key: "ctrl+q", label: "stop and quit", run: quit },
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
