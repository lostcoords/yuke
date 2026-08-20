// Control-plane Account handle. A Session token (`yk_sess_…`) or a browser cookie
// can list daemons and mint connect tickets. A device credential (`yk_dev_…`) is
// refused: that secret parks a daemon and must not be used as a client.
import { decodeRosterPin, fetchConnectTicket, fetchDeviceRoster, parseRosterDevices, } from "./roster.js";
import { Client } from "./client.js";
import { discoverDaemon } from "./discovery.js";
const SESSION_PREFIX = "yk_sess_";
const DEVICE_PREFIX = "yk_dev_";
export class Account {
    url;
    #auth;
    constructor(url, auth) {
        this.url = url.replace(/\/$/, "");
        this.#auth = auth;
    }
    /** Authenticate with a minted session token (`yk_sess_…`). */
    static fromSession(opts) {
        if (!opts.token.startsWith(SESSION_PREFIX)) {
            throw new Error("Account.fromSession expects a yk_sess_ token (not a device credential)");
        }
        if (opts.token.startsWith(DEVICE_PREFIX)) {
            throw new Error("Account.fromSession refuses a device credential");
        }
        return new Account(opts.url, { kind: "session", token: opts.token });
    }
    /** Authenticate with the shared browser cookie (credentials: include). */
    static fromBrowser(opts) {
        return new Account(opts.url, { kind: "browser" });
    }
    async devices() {
        if (this.#auth.kind === "browser") {
            return fetchDeviceRoster(this.url);
        }
        return fetchApiRoster(this.url, this.#auth.token);
    }
    async connectTicket(deviceId) {
        if (this.#auth.kind === "browser") {
            return fetchConnectTicket(deviceId, this.url);
        }
        return fetchApiConnectTicket(this.url, this.#auth.token, deviceId);
    }
    /** Who this account is. Cookie → `/browser/profile`; token → `/api/v1/profile`. */
    async profile() {
        if (this.#auth.kind === "browser") {
            return fetchJsonProfile(`${this.url}/browser/profile`, { credentials: "include" });
        }
        return fetchJsonProfile(`${this.url}/api/v1/profile`, {
            headers: { Authorization: `Bearer ${this.#auth.token}` },
        });
    }
}
/** Direct daemon connection. Host and port are required — no localhost default. */
export async function connect(opts) {
    const endpoint = await discoverDaemon({
        host: opts.host,
        port: opts.port,
        ...(opts.secure !== undefined ? { secure: opts.secure } : {}),
    });
    const wsUrl = endpoint?.wsUrl ?? `${opts.secure ?? false ? "wss" : "ws"}://${opts.host}:${opts.port}/ws`;
    const client = await Client.connect(wsUrl, { client: opts.client });
    return { client, endpoint };
}
export { decodeRosterPin };
async function fetchJsonProfile(url, init) {
    let response;
    try {
        response = await fetch(url, {
            ...init,
            headers: { Accept: "application/json", ...init.headers },
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
        if (typeof body.email_address !== "string" || body.email_address.length === 0) {
            return { status: "error", detail: "missing email_address" };
        }
        const account_name = typeof body.account_name === "string" && body.account_name.length > 0 ? body.account_name : null;
        return { status: "ok", profile: { email_address: body.email_address, account_name } };
    }
    catch (error) {
        return { status: "error", detail: error instanceof Error ? error.message : "malformed JSON" };
    }
}
async function fetchApiRoster(baseUrl, token) {
    let response;
    try {
        response = await fetch(`${baseUrl}/api/v1/devices`, {
            headers: { Accept: "application/json", Authorization: `Bearer ${token}` },
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
async function fetchApiConnectTicket(baseUrl, token, deviceId) {
    let response;
    try {
        response = await fetch(`${baseUrl}/api/v1/connect_tickets`, {
            method: "POST",
            headers: {
                Accept: "application/json",
                "Content-Type": "application/json",
                Authorization: `Bearer ${token}`,
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
            /* keep */
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
        const expires = typeof body.expires_at === "string" ? Date.parse(body.expires_at) : NaN;
        const ticket = {
            ticket: body.ticket,
            relay_url: body.relay_url,
            expires_at_ms: Number.isNaN(expires) ? 0 : expires,
        };
        return { status: "ok", ticket };
    }
    catch (error) {
        return { status: "error", detail: error instanceof Error ? error.message : "malformed JSON" };
    }
}
//# sourceMappingURL=account.js.map