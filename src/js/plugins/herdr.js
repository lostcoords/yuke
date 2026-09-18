import { client, env, net, services, utf8 } from "yuke";

const source = "custom:yuke";
const timeoutMs = 250;
const frameLimit = 4096;
const maxAttempts = 3;

/** @returns {import("../app/types/ext.js").Plugin} */
export function herdr() {
  /** @type {undefined | (() => Promise<void>)} */
  let stop;
  return {
    name: "herdr",
    apply(ctx) {
      stop = undefined;
      if (!services.has("tui") || env.get("HERDR_ENV") !== "1") return;
      const path = env.get("HERDR_SOCKET_PATH");
      const pane = env.get("HERDR_PANE_ID");
      if (!path || !pane) return;
      const socketPath = path;
      const signal = ctx.signal;
      let stopped = false;
      let id = 0;
      let attempts = 0;
      let retry = 0;
      let desired = "";
      let acknowledged = "";
      /** @type {Promise<void> | undefined} */
      let active;
      /** @type {import("yuke:net-native").Socket | undefined} */
      let socket;

      /** @param {string} method @param {Record<string, string>} params @param {boolean} cleanup */
      async function request(method, params, cleanup) {
        const requestId = String(++id);
        const bytes = utf8.encode(JSON.stringify({ id: requestId, method, params: { pane_id: pane, source, ...params } }) + "\n");
        if (bytes.length > frameLimit) throw new Error("Herdr request exceeds the byte limit");
        const options = cleanup ? { timeoutMs } : { timeoutMs, signal };
        let expired = false;
        // One timer bounds the whole exchange, including partial response reads.
        const deadline = setTimeout(() => { expired = true; socket?.close(); }, timeoutMs);
        try {
          socket = await net.connect({ path: socketPath, ...options });
          if (expired || (stopped && !cleanup)) throw new Error("Herdr request canceled");
          await socket.write(bytes, options);
          const frame = new Uint8Array(frameLimit);
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
        if (stopped || active || retry || desired === acknowledged || attempts === maxAttempts) return;
        const state = desired;
        attempts++;
        active = request("pane.report_agent", { agent: "yuke", state }, false)
          .then(() => { acknowledged = state; }, () => { acknowledged = ""; })
          .then(() => {
            active = undefined;
            if (stopped || desired === acknowledged) return;
            if (desired !== state) schedule();
            else if (attempts < maxAttempts) retry = setTimeout(() => { retry = 0; schedule(); }, timeoutMs);
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

      function cancel() {
        stopped = true;
        clearTimeout(retry);
        socket?.close();
      }

      ctx.own(cancel);
      ctx.on("interaction.changed", refresh);
      ctx.on("engine.activity.changed", refresh);
      stop = async () => {
        cancel();
        await active;
        // Cleanup has its own deadline because the plugin signal is already canceled.
        try { await request("pane.clear_agent_authority", {}, true); } catch {}
      };
      refresh();
    },
    stop() { return stop?.(); },
  };
}
