// yuke:queue — the queued inputs of each open session: rows above the rule, a picker that drops one, and a clear command.
import { root } from "yuke:core";
import { clip } from "yuke:text-input";
import { ui } from "yuke:ui";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { inputSourceLabel } from "yuke:transcript";
import { ChatView } from "yuke:chat-view";
import { chatOf, focusedChat } from "yuke:chat";

/** @import { Context } from "yuke:ext" */
/** @import { InjectContext as Ctx } from "./types/ext.js" */

// The rows the strip shows before it folds the rest into a count.
const STRIP_ROWS = 3;

// The queue of each session the activity module tracks. A read replaces the whole list.
/** @type {Map<string, readonly Wire.QueuedInput[]>} */
const held = new Map();
// The read generation per session. A result lands only while its generation is the latest, so a stale read never wins.
/** @type {Map<string, number>} */
const gens = new Map();

/** @param {string} sessionId @returns {readonly Wire.QueuedInput[]} */
export function queueOf(sessionId) {
  return held.get(sessionId) || [];
}

// The first line of a queued input, with a mark for each part that is not text.
/** @param {Wire.QueuedInput} input @returns {string} */
export function queuedText(input) {
  if (protectedInput(input)) return "[protected] " + inputSourceLabel(input.source);
  const words = [];
  for (const part of input.content) {
    if (part.type === "text") words.push(part.text);
    else words.push("[" + part.type + "]");
  }
  const joined = words.join(" ").trim();
  const nl = joined.indexOf("\n");
  return nl < 0 ? joined : joined.slice(0, nl) + "…";
}

/** @param {Wire.QueuedInput} input @returns {boolean} */
export function protectedInput(input) { return input.source != null && input.source.type !== "parent_instruction"; }

/** @param {string} sessionId */
export async function clearWorkQueue(sessionId) {
  const items = (await client.sessionQueue(sessionId)).items;
  const work = items.filter((item) => !protectedInput(item));
  const results = await Promise.allSettled(work.map((item) => client.sessionCancelInput(sessionId, item.input_id)));
  const removed = results.filter((result) => result.status === "fulfilled").length;
  return { removed, failed: work.length - removed, protected: items.length - work.length };
}

// Read the queue again. Each call is a new generation, so the newest read is the one that lands.
/** @param {string} sessionId @returns {Promise<void>} */
export function refreshQueue(sessionId) {
  const gen = (gens.get(sessionId) || 0) + 1;
  gens.set(sessionId, gen);
  return client
    .sessionQueue(sessionId)
    .then((r) => {
      if (gens.get(sessionId) === gen) held.set(sessionId, r.items);
    })
    .catch(() => {})
    .then(() => root.invalidate());
}

// Drop the queue of a session no pane holds. A read still in flight lands on a stale generation and is ignored.
/** @param {string} sessionId @returns {void} */
function forget(sessionId) {
  held.delete(sessionId);
  gens.delete(sessionId);
  root.invalidate();
}

// The rows a pane shows: the oldest inputs first, then one row for the rest.
/** @param {readonly Wire.QueuedInput[]} items @returns {{ text: string, group: string }[]} */
export function stripRows(items) {
  const rows = [];
  const shown = items.length > STRIP_ROWS ? STRIP_ROWS - 1 : items.length;
  for (let i = 0; i < shown; i++) rows.push({ text: " ↳ " + queuedText(/** @type {Wire.QueuedInput} */ (items[i])), group: "UIDim" });
  if (items.length > shown) rows.push({ text: " ↳ … " + (items.length - shown) + " more queued", group: "UIDim" });
  return rows;
}

// Drop one input. The engine announces the shorter queue, so the strip follows on its own.
/** @param {string} sessionId @param {Wire.QueuedInput} input @returns {Promise<void>} */
function cancelOne(sessionId, input) {
  if (protectedInput(input)) { notice.show("engine reports and notices stay queued"); return Promise.resolve(); }
  return client.sessionCancelInput(sessionId, input.input_id).then(
    () => notice.show("dropped · " + clip(queuedText(input), 40)),
    (e) => notice.show("cannot drop · " + ((e && e.message) || "unknown")),
  );
}

/** @param {Ctx} ctx @param {string} sessionId @returns {void} */
function openQueuePicker(ctx, sessionId) {
  const items = queueOf(sessionId);
  if (items.length === 0) {
    notice.show("nothing queued");
    return;
  }
  const p = ui.pick({
    title: "queued · " + items.length,
    footer: "↵ drop · esc close",
    border: "rounded",
    width: max => Math.round(max * 0.6),
    height: max => Math.round(max * 0.4),
    items: items.slice(),
    isSelectable: (q) => !protectedInput(q),
    key: (q) => String(q.input_id),
    filterText: queuedText,
    format: (q) => ({ text: queuedText(q) }),
    onAccept: (q) => {
      cancelOne(sessionId, q);
    },
  });
  ctx.tui.overlay(p.win);
}

export const queuePlugin = {
  name: "queue",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    ctx.inject(["tui"], (ctx) => {
      // The engine announces the activity on every queue change, so the count is the one trigger to read again.
      ctx.on("activity.changed", /** @param {string} id @param {Wire.SessionActivity | null} a */ (id, a) => {
        if (!a) forget(id);
        else if (a.queued !== queueOf(id).length) refreshQueue(id);
      });

      ctx.tui.slot(ChatView, "strip", /** @param {ChatView} view */ (view) => {
        const c = chatOf(view);
        return c && c.sessionId ? stripRows(queueOf(c.sessionId)) : null;
      });

      const hasQueue = () => {
        const c = focusedChat();
        return c != null && c.sessionId != null && queueOf(c.sessionId).length > 0;
      };
      ctx.tui.command(hasQueue, {
        "queue:drop": () => {
          const c = focusedChat();
          if (c && c.sessionId) openQueuePicker(ctx, c.sessionId);
        },
        "queue:clear": () => {
          const c = focusedChat();
          if (!c || !c.sessionId) return;
          const id = c.sessionId;
          clearWorkQueue(id).then((result) => {
            notice.show("queue · removed " + result.removed + " · failed " + result.failed + " · protected " + result.protected);
          }, (error) => notice.show("cannot clear queue · " + error.message));
        },
      }, {
        "queue:drop": { title: "Queue", description: "drop one queued message", slash: "queue" },
        "queue:clear": { title: "Clear queue", description: "drop queued work; preserve engine reports", slash: "clear-queue" },
      });

      ctx.effect(() => () => {
        held.clear();
        gens.clear();
      });
    });
  },
};
