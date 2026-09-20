// yuke:quit — hold a quit while a run works. A second ask inside the window leaves, and the engine close cancels the runs.
import { keymap } from "yuke:core";
import { term } from "yuke:term";
import { client } from "yuke:client";
import { notice } from "yuke:notice";
import { agentsLabel } from "yuke:activity";

/** @import { Context } from "yuke:ext" */
/** @import { EngineLoad } from "yuke:engine-native" */

// A second ask inside this window confirms; fx and Gemini CLI use the same three seconds.
const WINDOW_MS = 3000;

/** The work a quit would stop, then the stroke that runs quit here, or the slash word when no key does. */
/** @param {EngineLoad} load @returns {string} */
function hint(load) {
  const work = load.childRuns > 0 ? agentsLabel(load.childRuns) + " working" : "a run in progress";
  return work + " · " + (keymap.hints().quit || "/quit") + " again to stop it and quit";
}

export const quitGuard = {
  name: "quit-guard",
  /** @param {Context} ctx @returns {void} */
  apply(ctx) {
    // The wall-clock time of the first ask, or 0 while no ask is armed.
    let armedAt = 0;
    ctx.on("quit.requested", () => {
      const load = client.load();
      if (load.runs === 0 && load.continuations === 0) return false;
      const now = Date.now();
      const elapsed = now - armedAt;
      // A wall clock can step back, so a negative age holds like an old one.
      if (armedAt !== 0 && elapsed >= 0 && elapsed <= WINDOW_MS) {
        term.quit();
        return true;
      }
      armedAt = now;
      notice.show(hint(load));
      return true;
    });
  },
};
