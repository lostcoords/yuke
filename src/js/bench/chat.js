import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { root } from "yuke:internal/core";
import { events } from "yuke:internal/kernel";
import { client } from "yuke:internal/client";
import "yuke:internal/defaults";

/** @import { ChatView } from "yuke:internal/chat-view" */
/** @import { EngineEvent } from "yuke:internal/native/engine" */

// The frontend boots this way, so each frame pays for the default plugins: the status bar, the rule, and the strip.
plugins.use(tuiPlugin);

// The engine appends these deltas to part 0 of draft 2, one for each step, in this order.
const DRAFT_ID = 2;
const PART_ID = 0;
const deltas = [" word", " 世界", " e\u0301", " 👩‍💻", "\n\n"];
// The engine sends one digest for each delta. The step reuses it, so the step measures the app and not the payload.
/** @type {Extract<EngineEvent, { type: "session" }>} */
const digest = { type: "session", session: "", kind: "active", id: DRAFT_ID, part: PART_ID, facts: [] };

/** @type {ChatView} */
let chat;
let phase = "", steps = 0, initial = "";

/** @param {string} name @returns {number} */
function start(name) {
  phase = name;
  steps = 0;
  chat = /** @type {ChatView} */ (root.active);
  if (!chat || !chat.transcript) throw new Error("the shell mounted no chat pane");
  // The bench owns no pin, so it names the session directly, as the agents bench does.
  chat.transcript.setOutline([], null);
  chat.session.sessionId = globalThis.PROJECTION_SESSION;
  digest.session = globalThis.PROJECTION_SESSION;
  chat.session.reload();
  chat.transcript.pager.toBottom();
  root.flush();
  if (phase === "chat_stream") {
    const part = client.sessionPart(globalThis.PROJECTION_SESSION, DRAFT_ID, PART_ID)?.part;
    if (!part || part.type !== "text") throw new Error("chat stream part missing");
    initial = part.text;
  }
  return 1;
}

/** @returns {number} */
function step() {
  steps++;
  if (phase === "chat_stream") events.emit("session.changed", digest);
  else root.invalidate();
  root.flush();
  return 1;
}

/** @returns {number} */
function verify() {
  if (chat.transcript.rowCount(chat.transcriptRect.w) === 0) throw new Error("empty chat frame");
  if (phase !== "chat_stream") return steps;
  let appended = "";
  for (let i = 0; i < steps; i++) appended += deltas[i % deltas.length] || "";
  if (chat.transcript._sourceOf(DRAFT_ID) !== initial + appended) throw new Error("chat stream source changed");
  return steps;
}

globalThis.bench = { start, step, verify };
