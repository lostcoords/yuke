// Control-plane HTTP primitives a browser client speaks outside the wire protocol:
// device roster (`GET /browser/devices`) and connect tickets (`POST /browser/connect_tickets`).
// Session-authed via the shared `.yuke.sh`/`.lvh.me` cookie. No runtime dependencies.
/** X25519 static public key size in bytes (Noise pin). */
export const ROSTER_PIN_BYTES = 32;
// ISO-8601 (or null) → epoch ms (or null).
function toEpochMs(iso) {
    if (iso === null || iso === undefined)
        return null;
    const ms = Date.parse(iso);
    return Number.isNaN(ms) ? null : ms;
}
function toDevice(entry) {
    return {
        device_id: entry.device_id,
        name: entry.name,
        kind: entry.kind === "hosted" ? "hosted" : "owned",
        platform: entry.platform,
        online: entry.online,
        online_since: toEpochMs(entry.online_since),
        last_seen_at: toEpochMs(entry.last_seen_at),
        is_self: entry.is_self,
        static_public_key: typeof entry.static_public_key === "string" ? entry.static_public_key : "",
    };
}
/**
 * Decode a roster entry's base64 `static_public_key` into the 32 raw bytes a Noise initiator pins.
 * Returns `null` when the string is not valid base64 or not exactly 32 decoded bytes.
 */
export function decodeRosterPin(staticPublicKey) {
    if (staticPublicKey.length === 0)
        return null;
    try {
        // atob is available in browsers and Node 22+ (global).
        const bin = atob(staticPublicKey);
        if (bin.length !== ROSTER_PIN_BYTES)
            return null;
        const out = new Uint8Array(ROSTER_PIN_BYTES);
        for (let i = 0; i < ROSTER_PIN_BYTES; i += 1)
            out[i] = bin.charCodeAt(i);
        return out;
    }
    catch {
        return null;
    }
}
/**
 * Fetch the signed-in account's device roster. `baseUrl` is the control-plane origin — empty in dev,
 * where the SPA proxies `/browser/*` to it same-origin; the deployed origin in production.
 */
/** Parse a control-plane roster JSON body into Device rows. */
export function parseRosterDevices(body) {
    return (body.devices ?? []).map(toDevice);
}
export async function fetchDeviceRoster(baseUrl = "") {
    let response;
    try {
        response = await fetch(`${baseUrl}/browser/devices`, {
            credentials: "include",
            headers: { Accept: "application/json" },
        });
    }
    catch (error) {
        return { status: "error", detail: error instanceof Error ? error.message : "network error" };
    }
    if (response.status === 401)
        return { status: "unauthenticated" };
    if (!response.ok)
        return { status: "error", detail: `HTTP ${response.status}` };
    try {
        const body = (await response.json());
        return { status: "ok", devices: parseRosterDevices(body) };
    }
    catch (error) {
        return { status: "error", detail: error instanceof Error ? error.message : "malformed JSON" };
    }
}
/** GET /browser/csrf → token for state-changing browser POSTs. */
async function fetchBrowserCsrf(baseUrl) {
    try {
        const response = await fetch(`${baseUrl}/browser/csrf`, {
            credentials: "include",
            headers: { Accept: "application/json" },
        });
        if (!response.ok)
            return null;
        const body = (await response.json());
        return typeof body.csrf_token === "string" ? body.csrf_token : null;
    }
    catch {
        return null;
    }
}
/**
 * Issue a connect ticket for `deviceId` (POST /browser/connect_tickets). Fetches CSRF first.
 * On success dial the returned `relay_url` with {@link relayConnectUrl} and pin the device's
 * {@link decodeRosterPin static key}.
 */
export async function fetchConnectTicket(deviceId, baseUrl = "") {
    const csrf = await fetchBrowserCsrf(baseUrl);
    if (csrf === null) {
        return { status: "error", detail: "could not obtain CSRF token" };
    }
    let response;
    try {
        response = await fetch(`${baseUrl}/browser/connect_tickets`, {
            method: "POST",
            credentials: "include",
            headers: {
                Accept: "application/json",
                "Content-Type": "application/json",
                "X-CSRF-Token": csrf,
            },
            body: JSON.stringify({ device_id: deviceId }),
        });
    }
    catch (error) {
        return { status: "error", detail: error instanceof Error ? error.message : "network error" };
    }
    if (response.status === 401)
        return { status: "unauthenticated" };
    if (response.status === 403) {
        let detail = "forbidden";
        try {
            const body = (await response.json());
            detail = body.detail ?? body.code ?? detail;
        }
        catch {
            /* keep default */
        }
        return { status: "forbidden", detail };
    }
    if (response.status === 404)
        return { status: "not_found" };
    if (!response.ok)
        return { status: "error", detail: `HTTP ${response.status}` };
    try {
        const body = (await response.json());
        if (typeof body.ticket !== "string" || typeof body.relay_url !== "string") {
            return { status: "error", detail: "malformed ticket response" };
        }
        const expires = typeof body.expires_at === "string" ? toEpochMs(body.expires_at) : null;
        return {
            status: "ok",
            ticket: {
                ticket: body.ticket,
                relay_url: body.relay_url,
                expires_at_ms: expires ?? 0,
            },
        };
    }
    catch (error) {
        return { status: "error", detail: error instanceof Error ? error.message : "malformed JSON" };
    }
}
//# sourceMappingURL=roster.js.map