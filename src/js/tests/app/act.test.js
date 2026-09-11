import { equal } from "yuke:test";
import { command, root, status, keymap } from "yuke:core";
import { plugins } from "yuke:ext";
import "yuke:term";
import { chat } from "yuke:defaults";
import { chats, chatOf } from "yuke:chat";
import { feedOf } from "yuke:sessions";
const fail = [];
// The shell loads the notice as a plugin, so its segment and listeners can be taken back out.
if (!plugins.get("notice")) fail.push("notice-plugin");
if (!plugins.get("command-ui")) fail.push("command-ui-plugin");
if (!plugins.get("catalog")) fail.push("catalog-plugin");
if (!plugins.get("chat")) fail.push("chat-plugin");
if (!plugins.get("explorer")) fail.push("explorer-plugin");
if (!command.available("catalog:reload")) fail.push("catalog-reload-command");
if (!command.available("suspend")) fail.push("suspend-command");
{
  const z = keymap.describe("ctrl+z").winner;
  if (!z || z.binding !== "suspend") fail.push("suspend-key");
}


// The status bar reports a pending key.
{
  root.focusView(chat.view);
  // A `g` prefix only arms outside the composer, so the transcript takes the focus first.
  chat.view.focus = "transcript";
  const g = { type: "key", code: "char", char: "g", text: "g", event: "press", mods: 0 };
  const beforeG = status.side("right");
  root.onEvent(g);
  if (keymap.pendingLabel() !== "g") fail.push("showcmd-armed");
  if (status.side("right") === beforeG) fail.push("showcmd-on");
  root.onEvent(g);
  if (keymap.pendingLabel() !== "") fail.push("showcmd-off");
  chat.view.focus = "composer";
  root.focusView(chat.view);
}
// Tab moves the region focus with no vim plugin loaded.
{
  const tab = { type: "key", code: "tab", char: "", text: "", event: "press", mods: 0 };
  if (chat.view.focus !== "composer") fail.push("boot-region");
  root.onEvent(tab);
  if (chat.view.focus !== "transcript") fail.push("tab-to-transcript");
  root.onEvent(tab);
  if (chat.view.focus !== "composer") fail.push("tab-back");
}
command.perform("ui:palette");
if (root.overlays.length !== 1) fail.push("palette");
root.popOverlay();
// PageUp scrolls the history while the composer types, through the nav binding.
{
  root.focusView(chat.view);
  if (root.navTarget() !== chat.transcript.pager) fail.push("chat-nav-target");
  let paged = 0;
  const realPage = chat.transcript.pager.navPage.bind(chat.transcript.pager);
  chat.transcript.pager.navPage = (d) => { paged = d; return realPage(d); };
  root.onEvent({ type: "key", code: "page_up", char: "", text: "", event: "press", mods: 0 });
  if (paged !== -1) fail.push("pageup-while-typing");
  chat.transcript.pager.navPage = realPage;
}

// The catalog readings must come through the shell's own wiring, not a test's own callbacks.
{
  const feed = feedOf();
  feed.seed({ items: [{ session: { id: "probe", model: "wired-model", message_count: 3, updated_at_ms: 1 },
    activity: { state: { type: "idle" }, queued: 0, context_usage: { input: 2500 }, pending_compaction: null } }] });
  chat.sessionId = "probe";
  const right = status.side("right");
  if (right.indexOf("wired-model") < 0) fail.push("catalog-entry-wired");
  if (right.indexOf("2.5k context") < 0) fail.push("context-usage-wired");

  // Closing the session clears the reading, so the status does not name a gone session.
  chat.sessionGone();
  chat.sessionId = null;
  feed.clear();
  if (status.side("right").indexOf("wired-model") >= 0) fail.push("catalog-entry-clears");
}


// The split command builds a real chat pane, and a tree with no leaf keeps no orphan.
{
  const before = chats.size;
  command.perform("window:split-right");
  if (chats.size !== before + 1) fail.push("split-makes-a-chat");
  if (chatOf(root.active) == null) fail.push("split-focuses-the-new-chat");
  command.perform("window:close");
  if (chats.size !== before) fail.push("close-releases-the-chat");
  const saved = root.root_node;
  root.setRoot(null);
  const empty = chats.size;
  command.perform("window:split-right");
  if (chats.size !== empty) fail.push("failed-split-keeps-no-orphan");
  root.setRoot(saved);
}
// The shell's own plugin owns the pending-key reading, so an unload takes it away.
{
  root.focusView(chat.view);
  // A test-owned prefix outlives the shell's bindings, so the pending stroke survives disposal.
  const offPrefix = keymap.add({ "f9 x": () => true });
  const f9 = { type: "key", code: "f9", char: "", text: "", event: "press", mods: 0 };
  root.onEvent(f9);
  if (status.side("right").indexOf("f9") < 0) fail.push("showcmd-drawn");
  keymap.pending = null;
  plugins.dispose("app-keys");
  root.onEvent(f9);
  if (keymap.pendingLabel() !== "f9") fail.push("showcmd-still-pending");
  if (status.side("right").indexOf("f9") >= 0) fail.push("showcmd-unloads");
  keymap.pending = null;
  offPrefix();
  root.focusView(chat.view);
}
equal(fail.length ? fail.join(",") : "ok", "ok");
