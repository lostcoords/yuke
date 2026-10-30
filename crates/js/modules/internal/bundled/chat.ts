/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript, composer,
 * folds, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session,
 * the draft, the folds, and the scroll place of each pane. Each command acts on the active pane. The service `chat`
 * shows a session in a pane for other plugins.
 */

import { readTextFile } from "yuke:fs";
import { type Chat, chatPane, type PaneActions, type PaneState } from "yuke:internal/bundled/chat/pane";
import { STYLES } from "yuke:internal/bundled/chat/rows";
import type { PluginContext } from "yuke:plugins";
import type { ModelInfo, ModelReference, ReasoningLevel } from "yuke:protocol";
import type { Infer } from "yuke:tools";
import type { View } from "yuke:tui";

export const optionsSchema = {
  type: "object",
  properties: {
    copyOnRelease: {
      type: "boolean",
      description: "Copy a mouse selection of the transcript when the button goes up. The default is true.",
    },
    questions: {
      type: "string",
      enum: ["composer", "modal"],
      description:
        "Show the question of a plugin in the place of the composer, or in a modal. The default is composer.",
    },
  },
} as const;

type Options = Infer<typeof optionsSchema>;

/** The cells of the gauge of the token share of the last answer. */
const GAUGE = 6;

/** The commands of the chat: the name, the description, the keys, their context, and the action. Each action uses the active pane. */
const COMMANDS: readonly {
  readonly name: string;
  readonly description: string;
  readonly keys: readonly string[];
  readonly in: "chat" | "composer" | "transcript" | "question";
  readonly run: (pane: PaneActions) => void;
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
    name: "switch-focus",
    description: "Move the focus between the composer and the transcript",
    keys: ["tab", "shift+tab"],
    in: "chat",
    run: (pane) => pane.switchFocus(),
  },
  {
    name: "activate",
    description: "Act on the caret",
    keys: ["enter"],
    in: "transcript",
    run: (pane) => pane.activate(),
  },
  { name: "copy", description: "Copy the selection", keys: ["y"], in: "transcript", run: (pane) => pane.copy() },
  {
    name: "cancel-question",
    description: "Cancel the question of a plugin",
    keys: ["esc", "ctrl+c"],
    in: "question",
    run: (pane) => pane.cancelQuestion(),
    enabled: (pane) => pane.asking(),
  },
];

export function apply(ctx: PluginContext<Options>): undefined {
  const tui = ctx.get("tui");
  const listeners = new Set<(view: View) => void>();
  const panes = new WeakMap<View, PaneActions>();
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
  });
  if (tui === undefined) return undefined;
  for (const [name, style] of Object.entries(STYLES)) tui.styles.set(name, style);
  const chat: Chat = {
    ctx,
    tui,
    copyOnRelease: ctx.options.copyOnRelease ?? true,
    questions: ctx.options.questions ?? "composer",
    panes,
    refresh: () => publish(),
    chosen: (choice) => {
      saved = choice;
      publish();
    },
    drafts: new Map(),
    moved: (view) => {
      for (const listener of listeners) {
        try {
          listener(view);
        } catch (error) {
          listeners.delete(listener);
          ctx.notify("error", `a listener of the chat failed: ${String(error)}`);
        }
      }
    },
  };
  // The first send of a pane without a session uses this pick, so the bar shows it.
  let saved: { readonly model: ModelReference; readonly reasoning: ReasoningLevel } | undefined;
  readTextFile("choice.json", { baseDir: ctx.dataDir, fatal: true })
    .then((text) => JSON.parse(text))
    .then(
      (choice) => {
        // A pick of the user can come before the end of this read, and the newer pick wins.
        saved ??= choice;
        publish();
      },
      // A missing file shows no model. The first send reports a broken file.
      () => {},
    );
  const active = (): PaneActions | undefined => {
    const view = tui.panes.active?.view;
    return view === undefined ? undefined : chat.panes.get(view);
  };
  // The catalog names the context window and the reasoning levels of each model, by provider/model.
  let models: ReadonlyMap<string, ModelInfo> | undefined;
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
        publish();
      },
      // Without the catalog, the model item has no level, and the context item is a token count.
      () => {},
    );
  /** Show the model, the token share of the last answer, and the jobs of the focused chat pane, or nothing. */
  const publish = (): void => {
    // The catalog and the end of a handle can come after the stop of the plugin, when its tui takes no more calls.
    if (ctx.signal.aborted) return;
    const status = active()?.status();
    const settings = status?.settings;
    if (status === undefined || settings === undefined) {
      for (const key of ["context", "jobs"]) tui.status.delete(key);
      // A pane without a session shows the saved pick that its first send uses, while the catalog still has it.
      const pick = status === undefined || status.bound ? undefined : saved;
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
        if (pane !== undefined) command.run(pane);
      },
      // A command of the chat runs only in a chat pane, so the palette of another pane leaves it out.
      enabled: () => {
        const pane = active();
        return pane !== undefined && (command.enabled?.(pane) ?? true);
      },
    });
    for (const key of command.keys) tui.keys.bind(key, command.name, { in: command.in });
  }
  return undefined;
}
