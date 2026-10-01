// Report this yuke pane as idle, working, or blocked to a local Herdr daemon.
// Herdr sets HERDR_ENV=1, HERDR_SOCKET_PATH, and HERDR_PANE_ID for the process.
import { client, env, net, plugins, utf8 } from "yuke";
/** @import { Plugin } from "yuke" */

const source = "custom:yuke";
const agent = "yuke";
const timeoutMs = 250;
const frameLimit = 4096;
const maxAttempts = 3;

/** @returns {Plugin} */
export function herdr() {
  return {
    name: "herdr",
    apply(ctx) {
      if (env.get("HERDR_ENV") !== "1") return;
      // A yuke that another agent starts inherits that agent's pane, so it must not report over that agent.
      if (env.get("AI_AGENT") || env.get("CLAUDECODE")) return;
      // Herdr reports the TUI state, so the reporter runs only while the TUI exists.
      ctx.inject(["tui"], (ctx) => {
        const path = env.get("HERDR_SOCKET_PATH");
        const pane = env.get("HERDR_PANE_ID");
        if (!path || !pane) return;
        const socketPath = path;
        let id = 0;
        // Herdr ignores a report whose seq is not above the last one it accepted, also across restarts, so seq follows the clock.
        let seq = 0;
        let attempts = 0;
        let retry = 0;
        let desired = "";
        let acknowledged = "";
        // Reports are serialized, and cleanup waits for the active report, so one frame is sufficient.
        const frame = new Uint8Array(frameLimit);
        /** @type {Promise<void> | undefined} */
        let active;
        /** @type {Awaited<ReturnType<typeof net.connect>> | undefined} */
        let socket;

        /** @param {string} method @param {Record<string, string>} params @param {boolean} cleanup */
        async function request(method, params, cleanup) {
          const requestId = String(++id);
          seq = Math.max(seq + 1, Date.now());
          const bytes = utf8.encode(JSON.stringify({ id: requestId, method, params: { pane_id: pane, source, agent, seq, ...params } }) + "\n");
          if (bytes.length > frameLimit) throw new Error("Herdr request exceeds the byte limit");
          const options = cleanup ? { timeoutMs } : { timeoutMs, signal: ctx.signal };
          let expired = false;
          // One timer bounds the whole exchange, including partial response reads.
          const deadline = setTimeout(() => { expired = true; socket?.close(); }, timeoutMs);
          try {
            socket = await net.connect({ path: socketPath, ...options });
            if (expired || (!cleanup && !ctx.alive)) throw new Error("Herdr request canceled");
            await socket.write(bytes, options);
            let used = 0;
            let complete = false;
            while (!expired) {
              const chunk = await socket.read({ ...options, maxBytes: complete ? 1 : frameLimit + 1 });
              if (expired) throw new Error("Herdr request timed out");
              if (chunk === null) {
                if (complete) return;
                throw new Error("Incomplete Herdr response");
              }
              for (let at = 0; at < chunk.length; at++) {
                if (complete) throw new Error("Extra Herdr response data");
                const byte = chunk[at];
                if (byte === 10) {
                  const value = JSON.parse(utf8.decode(frame.subarray(0, used)));
                  if (!value || Array.isArray(value) || value.id !== requestId ||
                      "error" in value || value.result?.type !== "ok") throw new Error("Invalid Herdr response");
                  complete = true;
                  continue;
                }
                if (used === frameLimit) throw new Error("Herdr response exceeds the byte limit");
                frame[used++] = /** @type {number} */ (byte);
              }
            }
            throw new Error("Herdr request timed out");
          } finally {
            clearTimeout(deadline);
            socket?.close();
            socket = undefined;
          }
        }

        function schedule() {
          if (!ctx.alive || active || retry || desired === acknowledged || attempts === maxAttempts) return;
          const state = desired;
          /** @type {unknown} */
          let failure;
          attempts++;
          active = request("pane.report_agent", { state }, false)
            .then(() => { acknowledged = state; }, (error) => { acknowledged = ""; failure = error; })
            .then(() => {
              active = undefined;
              if (!ctx.alive || desired === acknowledged) return;
              if (desired !== state) schedule();
              else if (attempts < maxAttempts) retry = setTimeout(() => { retry = 0; schedule(); }, timeoutMs);
              else ctx.print("Herdr report failed", failure);
            });
        }

        function refresh() {
          const state = ctx.interaction.pending > 0 ? "blocked" : client.isBusy() ? "working" : "idle";
          if (state !== desired) {
            desired = state;
            attempts = 0;
            clearTimeout(retry);
            retry = 0;
          }
          schedule();
        }

        // Disposal awaits this release; cleanup has its own deadline because the plugin signal is already canceled.
        ctx.own(async () => {
          clearTimeout(retry);
          socket?.close();
          await active;
          // Herdr documents release_agent as the exit report; it clears only the label that this source and agent hold.
          try { await request("pane.release_agent", {}, true); } catch {}
        });
        ctx.on("interaction.changed", refresh);
        ctx.on("engine.activity.changed", refresh);
        refresh();
      });
    },
  };
}

plugins.use(herdr());
