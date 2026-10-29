/**
 * The bundled plugin `chat`: the default pane of the terminal interface. Each pane has its own transcript, composer,
 * folds, and handle of its session. The start pane shows the session of `tui.startup`. A reload keeps the session,
 * the draft, the folds, and the scroll place of each pane. Each command acts on the active pane.
 */

import { type Chat, chatPane, type PaneActions, paneState } from "yuke:internal/bundled/chat/pane";
import { STYLES } from "yuke:internal/bundled/chat/rows";
import type { PluginContext } from "yuke:plugins";
import type { Infer } from "yuke:tools";

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
  if (tui === undefined) return undefined;
  for (const [name, style] of Object.entries(STYLES)) tui.styles.set(name, style);
  const chat: Chat = {
    ctx,
    tui,
    copyOnRelease: ctx.options.copyOnRelease ?? true,
    questions: ctx.options.questions ?? "composer",
    panes: new WeakMap(),
  };
  tui.views.register("pane", (state, mount) => chatPane(chat, mount, paneState(state)));
  tui.panes.setDefault((mount, reason) =>
    chatPane(chat, mount, { session: reason === "start" ? tui.startup.session : undefined }),
  );
  const active = (): PaneActions | undefined => {
    const view = tui.panes.active?.view;
    return view === undefined ? undefined : chat.panes.get(view);
  };
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
