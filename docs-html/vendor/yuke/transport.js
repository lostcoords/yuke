import { CLOSE_CODES, LIMITS } from "./generated/limits.js";
const OPEN = 1;
// One encoder for the module: every outbound frame is measured against the cap.
const UTF8 = new TextEncoder();
// WHATWG only permits 1000 or 3000-4999 from the initiating side, so the daemon's codes in
// CLOSE_CODES are for reading an inbound close, never for sending one.
const NORMAL_CLOSURE = 1000;
/** The default transport: one WebSocket carrying the whole session. */
export class WebSocketTransport {
    onmessage;
    onclose;
    onerror;
    #socket;
    #closed = false;
    #url;
    #options;
    /** Wrap a socket for `url`, opened on `start`. */
    constructor(url, options = {}) {
        this.#url = url;
        this.#options = options;
    }
    /** Open the socket. Rejects if it closes or errors before opening. */
    start() {
        const create = this.#options.createSocket ??
            ((url) => {
                if (typeof WebSocket !== "function") {
                    throw new Error("no global WebSocket; pass createSocket in WebSocketTransportOptions");
                }
                return new WebSocket(url);
            });
        const socket = create(this.#url);
        this.#socket = socket;
        return new Promise((resolve, reject) => {
            let settled = false;
            socket.addEventListener("open", () => {
                settled = true;
                resolve();
            });
            socket.addEventListener("message", (event) => {
                // Only text frames carry protocol; the wire has no binary frames.
                if (typeof event.data === "string")
                    this.onmessage?.(event.data);
            });
            socket.addEventListener("error", () => {
                const error = new Error(`websocket error for ${this.#url}`);
                if (settled)
                    this.onerror?.(error);
                else {
                    settled = true;
                    reject(error);
                }
            });
            socket.addEventListener("close", (event) => {
                this.#closed = true;
                const code = event.code ?? CLOSE_CODES.internal_error;
                const info = {
                    code,
                    reason: event.reason ?? "",
                    wasClean: event.wasClean ?? false,
                };
                if (!settled) {
                    settled = true;
                    reject(new Error(`websocket closed before opening: ${code}`));
                    return;
                }
                this.onclose?.(info);
            });
        });
    }
    /** Send one text frame. Throws if the socket is not open or the frame exceeds the wire cap. */
    send(frame) {
        const socket = this.#socket;
        if (socket === undefined || this.#closed || socket.readyState !== OPEN) {
            throw new Error("transport is not open");
        }
        // The daemon closes a connection whose frame exceeds the protocol cap, so failing here keeps
        // an oversized frame from taking the whole session down.
        const bytes = UTF8.encode(frame).byteLength;
        if (bytes > LIMITS.max_frame_bytes) {
            throw new Error(`frame is ${bytes} bytes, over the protocol cap of ${LIMITS.max_frame_bytes}`);
        }
        socket.send(frame);
    }
    /** Close the socket. Defaults to a normal closure. */
    close(code = NORMAL_CLOSURE, reason = "") {
        if (this.#closed)
            return;
        this.#closed = true;
        this.#socket?.close(code, reason);
    }
}
//# sourceMappingURL=transport.js.map