// yuke:command-ui — the command float: the slash menu under the composer text, and the same list on ctrl+p.
import { command, keymap, root } from "yuke:core";
import { ui } from "yuke:ui";
import { fuzzyRank } from "yuke:fzy";
import { Chat, focusedChat } from "yuke:chat";

/** @typedef {import("yuke:core").CommandListing & { hint: string }} Entry */
/** @typedef {import("yuke:ui").ListItem} ListItem */
/** @typedef {import("yuke:ui").PickOptions<Entry>["keymap"]} FloatKeymap */
/** @typedef {{ rows?: number, border?: import("yuke:ui").Border, format?: (entry: Entry, column: number) => string | ListItem, filterText?: (entry: Entry) => string, keymap?: FloatKeymap }} CommandUiConfig */
/** @typedef {{ word: string, rest: string, complete: boolean }} SlashLine */

// The first stroke that runs each command here. `candidates` drops what the context shadows.
/** @returns {Record<string, string>} */
function keyHints() {
  /** @type {Record<string, string>} */
  const hints = Object.create(null);
  for (const stroke in keymap.map) {
    const winner = keymap.candidates(stroke)[0];
    if (winner && typeof winner.fn === "string" && !(winner.fn in hints)) hints[winner.fn] = stroke;
  }
  return hints;
}

/** @returns {Entry[]} */
function entries() {
  const hints = keyHints();
  return command.list().map((c) => ({ ...c, hint: hints[c.name] || "" }));
}

/** @param {Entry} e @returns {string} */
function wordOf(e) {
  return e.slash ? "/" + e.slash : e.title;
}

// The name column: the widest word plus two cells, so every description starts on one column.
/** @param {Entry[]} all @returns {number} */
function columnOf(all) {
  let col = 10;
  for (const e of all) col = Math.max(col, wordOf(e).length + 2);
  return col;
}

/** @param {Entry} e @param {number} col @returns {ListItem} */
function formatRow(e, col) {
  return { text: wordOf(e).padEnd(col), detail: e.description + (e.hint ? " · " + e.hint : "") };
}

// The slash word and the rest of a composer text, or null when the text is a message. A token with a second `/` is a path.
/** @param {string} text @returns {SlashLine | null} */
export function parseSlash(text) {
  const line = text.trimStart();
  if (line[0] !== "/") return null;
  const end = line.search(/\s/);
  const word = end < 0 ? line.slice(1) : line.slice(1, end);
  if (word.indexOf("/") >= 0) return null;
  return { word, rest: end < 0 ? "" : line.slice(end).trim(), complete: end >= 0 };
}

// Run one command with the rest of the line as its argument. A bare call keeps the arity the action declares.
/** @param {Entry} e @param {string} rest @returns {void} */
function run(e, rest) {
  if (rest) command.perform(e.name, rest);
  else command.perform(e.name);
}

export const commandUiPlugin = {
  name: "command-ui",
  /** @param {import("yuke:ext").Context} ctx @param {unknown} [config] @returns {void} */
  apply(ctx, config) {
    const cfg = /** @type {CommandUiConfig} */ (config || {});
    const rows = cfg.rows || 6;
    const border = cfg.border || "none";
    const format = cfg.format || formatRow;

    ctx.inject(["tui"], (ctx) => {
      // The open float, with the chat it follows. One float at a time, because one composer has the focus.
      /** @type {{ chat: Chat, picker: import("yuke:ui").Picker<Entry>, win: import("yuke:ui").Window } | null} */
      let float = null;
      // The text Escape dismissed. The menu stays closed until the text changes.
      let dismissed = "";

      const close = () => {
        if (!float) return;
        root.popOverlay(float.win);
        float = null;
      };

      // Replace the composer text with the word. A command with an argument gets the space that starts it.
      /** @param {Chat} chat @param {Entry | null} e @returns {void} */
      const complete = (chat, e) => {
        if (e) chat.composer.text = "/" + e.slash + (e.args ? " " : "");
      };

      /** @param {Chat} chat @param {Entry[]} ranked @param {number} col @returns {void} */
      const open = (chat, ranked, col) => {
        /** @type {import("yuke:ui").Picker<Entry> | null} */
        let content = null;
        const p = ui.select(ranked, {
          name: "slash",
          modal: false,
          border,
          panelGroup: "UIFloat",
          anchor: () => chat.composer.rect,
          height: () => Math.min(rows, content ? content.list.items.length : 0),
          key: (e) => e.name,
          format: (e) => format(e, col),
          keymap: {
            up: "prev",
            "ctrl+p": "prev",
            down: "next",
            "ctrl+n": "next",
            tab: (_ev, content) => complete(chat, content.selected()),
            ...(cfg.keymap || {}),
          },
          // The picker closes its own window on accept and cancel, so the handle drops here.
          onAccept: (e) => {
            float = null;
            chat.composer.text = "";
            run(e, "");
          },
          onCancel: () => {
            float = null;
            dismissed = chat.composer.text;
          },
        });
        content = p.content;
        ctx.tui.overlay(p.win);
        float = { chat, picker: p.content, win: p.win };
      };

      // Follow the focused composer: open, refilter, or close the menu to match its text.
      const sync = () => {
        const chat = focusedChat();
        const typing = chat && root.active === chat.view && chat.view.focus === "composer";
        const line = typing ? parseSlash(chat.composer.text) : null;
        if (!chat || !line || line.complete || chat.composer.text === dismissed) return close();
        dismissed = "";
        if (float && float.chat !== chat) close();
        // Word order for an empty query, because the rows show words. Code-unit order, never localeCompare.
        const slashOf = (/** @type {Entry} */ e) => /** @type {string} */ (e.slash);
        const all = entries().filter((e) => e.slash).sort((a, b) => (slashOf(a) < slashOf(b) ? -1 : slashOf(a) > slashOf(b) ? 1 : 0));
        const ranked = fuzzyRank(all, line.word, slashOf);
        if (ranked.length === 0) return close();
        if (float) float.picker.setSource(ranked);
        else open(chat, ranked, columnOf(all));
      };
      ctx.on("composer.changed", sync);
      ctx.on("pane.focused", sync);
      ctx.on("region.focused", sync);
      ctx.on("pane.closed", sync);

      // A submitted slash line runs its command with the rest as the argument; any other text is a message.
      ctx.advise(Chat.prototype, "send", "around", /** @param {(text: string) => boolean} next @param {string} text */ (next, text) => {
        const line = parseSlash(text);
        const e = line ? entries().find((c) => c.slash === line.word) : null;
        if (!e) return next(text);
        run(e, line ? line.rest : "");
        return true;
      });

      // ctrl+p opens the same list as a modal picker with its own query, so a draft and a transcript focus both keep.
      const openPalette = () => {
        const all = entries();
        const col = columnOf(all);
        const chat = focusedChat();
        /** @type {import("yuke:ui").Picker<Entry> | null} */
        let content = null;
        const p = ui.pick({
          name: "commands",
          border,
          panelGroup: "UIFloat",
          anchor: chat ? () => chat.composer.rect : null,
          height: () => Math.min(rows, content ? content.list.items.length : 0) + 1,
          items: all,
          key: (e) => e.name,
          filterText: cfg.filterText || ((e) => wordOf(e) + " " + e.title),
          format: (e) => format(e, col),
          onAccept: (e) => run(e, ""),
        });
        content = p.content;
        ctx.tui.overlay(p.win);
        return p;
      };

      ctx.tui.command(null, { "ui:palette": openPalette });
      ctx.tui.keymap({ "ctrl+p": "ui:palette" });
    });
  },
};
