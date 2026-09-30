// The queued inputs of each open session: rows above the rule, a picker that drops one, and a clear command.
import { root } from "yuke:internal/core";
import { clip } from "yuke:internal/text-input";
import { ui } from "yuke:internal/ui";
import { client } from "yuke:internal/client";
import { inputSourceLabel } from "yuke:internal/transcript";
import { currentSession } from "yuke:internal/session";
import { errorText } from "yuke:internal/format";
import { notify } from "yuke:internal/kernel";

/** @import { Context } from "yuke:internal/ext" */
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
function protectedInput(input) { return input.source != null && input.source.type !== "parent_instruction"; }

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
function refreshQueue(sessionId) {
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

// The rows a pane shows: the oldest inputs first, then one row for the rest.
/** @param {readonly Wire.QueuedInput[]} items @returns {{ text: string, group: string }[]} */
export function stripRows(items) {
  const rows = [];
  const shown = items.length > STRIP_ROWS ? STRIP_ROWS - 1 : items.length;
  for (let i = 0; i < shown; i++) rows.push({ text: " ↳ " + queuedText(/** @type {Wire.QueuedInput} */ (items[i])), group: "UIDim" });
  if (items.length > shown) rows.push({ text: " ↳ … " + (items.length - shown) + " more queued", group: "UIDim" });
  return rows;
}

/** @param {Ctx} ctx @param {string} sessionId @returns {void} */
function openQueuePicker(ctx, sessionId) {
  const items = queueOf(sessionId);
  if (items.length === 0) {
    notify("info", "nothing queued", "queue");
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
    // Drop one input. The picker selects no protected input, and the engine announces the shorter queue, so the strip follows on its own.
    onAccept: (q) => {
      client.sessionCancelInput(sessionId, q.input_id).then(
        () => notify("info", "dropped · " + clip(queuedText(q), 40), "queue"),
        (e) => notify("error", "cannot drop · " + errorText(e), "queue"),
      );
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
      ctx.on("activity.changed", (id, a) => {
        // A session no pane holds drops its queue. A read still in flight lands on a stale generation and is ignored.
        if (!a) {
          held.delete(id);
          gens.delete(id);
          root.invalidate();
        } else if (a.queued !== queueOf(id).length) refreshQueue(id);
      });

      ctx.on("chat.strip", (view) => {
        const id = view.session.sessionId;
        return id ? stripRows(queueOf(id)) : null;
      });

      const hasQueue = () => {
        const id = currentSession()?.sessionId;
        return id != null && queueOf(id).length > 0;
      };
      ctx.tui.command.add("queue:drop", {
        when: hasQueue,
        desc: "drop one queued message",
        slash: "queue",
        run: () => {
          const id = currentSession()?.sessionId;
          if (id) openQueuePicker(ctx, id);
        },
      });
      ctx.tui.command.add("queue:clear", {
        when: hasQueue,
        desc: "drop queued work; preserve engine reports",
        slash: "clear-queue",
        run: () => {
          const id = currentSession()?.sessionId;
          if (!id) return;
          clearWorkQueue(id).then((result) => {
            notify(result.failed > 0 ? "error" : "info", "removed " + result.removed + " · failed " + result.failed + " · protected " + result.protected, "queue");
          }, (error) => notify("error", "cannot clear queue · " + errorText(error), "queue"));
        },
      });

      ctx.effect(() => () => {
        held.clear();
        gens.clear();
      });
    });
  },
};
