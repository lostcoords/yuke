import { check } from "yuke:internal/test";
import { command, keymap, root } from "yuke:internal/core";
import { term } from "yuke:internal/native/term";
import { Prompt, Window, ui } from "yuke:internal/ui";

const key = (code, o = {}) => ({ type: "key", code, char: "", shifted: "", baseLayout: "", text: "", event: "press", mods: 0, ...o });
const ctrl = (c) => key("char", { char: c, text: c, mods: 4 });
const press = (col, row) => ({ type: "mouse", col, row, button: "left", event: "press", mods: 0, count: 1 });
const dialogs = () => root.overlays.filter((o) => o.modal !== false);
let suspended = 0;
let quits = 0;
let interrupts = 0;
const realSuspend = term.suspend;
const realQuit = term.quit;
term.suspend = () => { suspended++; };
term.quit = () => { quits++; };
// A spy shadows the run interrupt, so the test sees whether ctrl+c reached it.
const offSpy = command.add("session:interrupt", { run: () => { interrupts++; } });

// ctrl+z runs suspend above an open dialog, and the dialog stays.
const first = ui.pick({ items: ["a", "b"], onAccept() {} });
root.pushOverlay(first.win);
root.onEvent(ctrl("z"));
check("suspend-above-dialog", suspended === 1 && dialogs().length === 1);
root.onEvent(ctrl("q"));
check("quit-above-dialog", quits === 1 && dialogs().length === 1);

// The pass-through follows the command, so a remap moves it with the key.
const offTaken = keymap.add({ "ctrl+z": "ui:palette" });
const offMoved = keymap.add({ "ctrl+x": "suspend" });
root.onEvent(ctrl("z"));
check("remapped-key-stays-in-dialog", suspended === 1);
root.onEvent(ctrl("x"));
check("new-key-passes", suspended === 2);
offTaken();
offMoved();

// ctrl+c cancels the dialog, as esc does, and never interrupts the run behind it.
root.onEvent(ctrl("c"));
check("ctrl-c-cancels", dialogs().length === 0 && interrupts === 0);

// A dialog that opens during a sequence clears it, so ctrl+c still cancels the dialog.
// The chat view reads ctrl+k first, so the test arms the window leader in the keymap itself.
keymap.onKey(ctrl("k"));
check("sequence-armed", keymap.owns());
const late = ui.pick({ items: ["a"], onAccept() {} });
root.pushOverlay(late.win);
check("dialog-clears-sequence", !keymap.owns());
root.onEvent(ctrl("c"));
check("ctrl-c-after-sequence", dialogs().length === 0);

// A press outside a picker cancels it. A press inside keeps it.
const second = ui.pick({ items: ["a", "b"], onAccept() {} });
root.pushOverlay(second.win);
root.flush();
root.onEvent(press(second.win.rect.x + 1, second.win.rect.y + 1));
check("inside-press-keeps", dialogs().length === 1);
root.onEvent(press(0, 0));
check("outside-press-cancels", dialogs().length === 0);

// A prompt window ignores a press outside, so the typed text stays. Esc would close it.
const held = new Window({ outsidePress: "ignore", width: 20, contentHeight: 1, content: new Prompt({ settle: () => root.popOverlay(held) }) });
root.pushOverlay(held);
root.flush();
root.onEvent(press(0, 0));
check("prompt-keeps", dialogs().length === 1);
root.popOverlay(held);
term.suspend = realSuspend;
term.quit = realQuit;
offSpy();
