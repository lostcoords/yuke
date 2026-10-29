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
  },
} as const;

type Options = Infer<typeof optionsSchema>;

/** The commands of the chat: the name, the title, the keys, their context, and the action. Each action uses the active pane. */
const COMMANDS: readonly {
  readonly name: string;
  readonly title: string;
  readonly keys: readonly string[];
  readonly in: "chat" | "composer" | "transcript";
  readonly run: (pane: PaneActions) => void;
  readonly enabled?: (pane: PaneActions) => boolean;
}[] = [
  { name: "send", title: "Send the message", keys: ["enter"], in: "composer", run: (pane) => pane.send() },
  {
    name: "older-message",
    title: "Show an older message of yours",
    keys: ["up"],
    in: "composer",
    run: (pane) => pane.browse(-1),
    enabled: (pane) => pane.canBrowse(),
  },
  {
    name: "newer-message",
    title: "Show a newer message of yours",
    keys: ["down"],
    in: "composer",
    run: (pane) => pane.browse(1),
    enabled: (pane) => pane.browsing(),
  },
  {
    name: "clear",
    title: "Clear the draft, or stop the turn",
    keys: ["ctrl+c"],
    in: "chat",
    run: (pane) => pane.clear(),
  },
  {
    name: "interrupt",
    title: "Drop the selection, or stop the turn",
    keys: ["esc"],
    in: "chat",
    run: (pane) => pane.interrupt(),
  },
  {
    name: "model",
    title: "Choose the model and the reasoning",
    keys: ["ctrl+k m"],
    in: "chat",
    run: (pane) => pane.chooseModel(),
  },
  {
    name: "toggle-tools",
    title: "Open or fold the tools",
    keys: ["ctrl+o"],
    in: "chat",
    run: (pane) => pane.toggleTools(),
  },
  { name: "page-up", title: "Scroll up one page", keys: ["page_up"], in: "chat", run: (pane) => pane.scroll("pageUp") },
  {
    name: "page-down",
    title: "Scroll down one page",
    keys: ["page_down"],
    in: "chat",
    run: (pane) => pane.scroll("pageDown"),
  },
  { name: "top", title: "Scroll to the top", keys: ["ctrl+home"], in: "chat", run: (pane) => pane.scroll("top") },
  {
    name: "bottom",
    title: "Scroll to the bottom",
    keys: ["ctrl+end"],
    in: "chat",
    run: (pane) => pane.scroll("bottom"),
  },
  {
    name: "switch-focus",
    title: "Move the focus between the composer and the transcript",
    keys: ["tab", "shift+tab"],
    in: "chat",
    run: (pane) => pane.switchFocus(),
  },
  { name: "activate", title: "Act on the caret", keys: ["enter"], in: "transcript", run: (pane) => pane.activate() },
  { name: "copy", title: "Copy the selection", keys: ["y"], in: "transcript", run: (pane) => pane.copy() },
];

export function apply(ctx: PluginContext<Options>): undefined {
  const tui = ctx.get("tui");
  if (tui === undefined) return undefined;
  for (const [name, style] of Object.entries(STYLES)) tui.styles.set(name, style);
  const chat: Chat = { ctx, tui, copyOnRelease: ctx.options.copyOnRelease ?? true, panes: new WeakMap() };
  tui.views.register("pane", (state, mount) => chatPane(chat, mount, paneState(state)));
  tui.panes.setDefault((mount, reason) =>
    chatPane(chat, mount, { session: reason === "start" ? tui.startup.session : undefined }),
  );
  const active = (): PaneActions | undefined => {
    const view = tui.panes.active?.view;
    return view === undefined ? undefined : chat.panes.get(view);
  };
  for (const command of COMMANDS) {
    const enabled = command.enabled;
    tui.commands.add({
      name: command.name,
      title: command.title,
      run: () => {
        const pane = active();
        if (pane !== undefined) command.run(pane);
      },
      ...(enabled === undefined
        ? {}
        : {
            enabled: () => {
              const pane = active();
              return pane !== undefined && enabled(pane);
            },
          }),
    });
    for (const key of command.keys) tui.keys.bind(key, command.name, { in: command.in });
  }
  return undefined;
}
