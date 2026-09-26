import { check } from "yuke:internal/test";
import { root } from "yuke:internal/core";
import { plugins } from "yuke:internal/ext";
import { tuiPlugin } from "yuke:internal/tui";
import { chatPlugin } from "yuke:internal/chat";
import { sessionsPlugin } from "yuke:internal/session";
import { shell } from "yuke:internal/shell";
/** @import { ChatView } from "yuke:internal/chat-view" */

plugins.use(tuiPlugin);
plugins.use(sessionsPlugin);
plugins.use(chatPlugin);
plugins.use(shell);
const view = /** @type {ChatView} */ (root.active);
root.flush();
// The draft has no message yet, so the hint takes the transcript region and the transcript takes none.
check("hint-shown", view.titleRect.h === 1 && view.hint.text.endsWith("type a message to start the session") && view.transcript.pager.rect() === null);

view.transcript.setOutline([{ id: 1, type: "user" }], null);
root.invalidate();
root.flush();
check("transcript-shown", view.titleRect.h === 0 && view.hintRect.h === 0 && view.transcript.pager.rect() !== null);
