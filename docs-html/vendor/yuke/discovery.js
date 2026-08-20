// Daemon discovery: probe a yuke daemon's `/identity`, so a client can prefer a direct `/ws`
// connection over the relay. Only the probe; the consumer composes the transport choice.
/** The daemon's baked-in default port that a client probes. */
export const DEFAULT_DAEMON_PORT = 9853;
/** The default host a client probes when none is given. */
export const DEFAULT_DAEMON_HOST = "localhost";
// Bounds a probe against a filtered port that would otherwise hang until the browser's own timeout.
const PROBE_TIMEOUT_MS = 1000;
function isLoopback(host) {
    return host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]";
}
/**
 * Probe `<scheme>://<host>:<port>/identity` for a yuke daemon. Resolves to its connection info, or
 * `null` when none answers — no daemon, a refused/blocked origin, a timeout, or a non-yuke reply.
 * Never throws: the absence of a daemon is the common case, not an error.
 *
 * Pass a bare port number for the common loopback case, or {@link DaemonProbeOptions} to target
 * another host (a LAN box, a self-hosted domain) and control TLS.
 */
export async function discoverDaemon(opts = {}) {
    const { host = DEFAULT_DAEMON_HOST, port = DEFAULT_DAEMON_PORT, secure } = typeof opts === "number" ? { port: opts } : opts;
    const tls = secure ?? !isLoopback(host);
    const httpScheme = tls ? "https" : "http";
    const wsScheme = tls ? "wss" : "ws";
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), PROBE_TIMEOUT_MS);
    try {
        const response = await fetch(`${httpScheme}://${host}:${port}/identity`, { signal: abort.signal });
        if (!response.ok) {
            return null;
        }
        const body = (await response.json());
        if (body.service !== "yuke") {
            return null;
        }
        const version = typeof body.version === "string" && body.version.length > 0 ? body.version : null;
        const deviceId = typeof body.device_id === "string" && body.device_id.length > 0 ? body.device_id : null;
        return { wsUrl: `${wsScheme}://${host}:${port}/ws`, version, deviceId };
    }
    catch {
        // No daemon listening, a CORS/network failure, an abort, or malformed JSON — all "no daemon".
        return null;
    }
    finally {
        clearTimeout(timer);
    }
}
//# sourceMappingURL=discovery.js.map