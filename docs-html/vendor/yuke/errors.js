import { ERROR_CODES } from "./generated/errors.js";
// Built once. `RpcError.from` runs on every error response, and scanning the code table per
// failure is work with a known answer.
const CODE_NAMES = new Map(Object.entries(ERROR_CODES).map(([name, code]) => [code, name]));
/** A request the daemon refused. `code` is the durable JSON-RPC number; branch on it, not on the message. */
export class RpcError extends Error {
    name = "RpcError";
    /** Durable JSON-RPC number; branch on this. */
    code;
    /** The artifact's name for `code`, when it is one the protocol defines. */
    codeName;
    /** Prefer `RpcError.from`, which fills in `codeName`. */
    constructor(code, message, codeName) {
        super(message);
        this.code = code;
        this.codeName = codeName;
    }
    /** Build one from a wire error, naming the code when the protocol defines it. */
    static from(code, message) {
        return new RpcError(code, message, CODE_NAMES.get(code));
    }
}
/** A frame that violated the protocol. The connection is not usable after one of these. */
export class ProtocolError extends Error {
    name = "ProtocolError";
}
/**
 * Delivery the receiver can prove it missed: a sequenced-broadcast hole, a shed droppable delta
 * detected by offset, or an explicit shed marker. None is recoverable by waiting — the session
 * must be resynced, which is why this surfaces rather than being logged.
 */
export class GapError extends Error {
    name = "GapError";
    /** The session whose stream has a gap. */
    sessionId;
    /** Which broadcast the gap was detected on. */
    broadcast;
    expected;
    received;
    /** Which check detected the loss. `shed` is an explicit marker (no stream offsets). */
    kind;
    /** Built by the client when it proves delivery was missed. */
    constructor(sessionId, broadcast, expected, received, kind) {
        super(kind === "shed"
            ? `shed gap on ${broadcast} for session ${sessionId}: ${received} delta(s) dropped; resync required`
            : `${kind} gap on ${broadcast} for session ${sessionId}: expected ${expected}, received ${received}; resync required`);
        this.sessionId = sessionId;
        this.broadcast = broadcast;
        this.expected = expected;
        this.received = received;
        this.kind = kind;
    }
}
/**
 * A broadcast consumer fell further behind than `BROADCAST_BACKLOG` events. The stream ends here
 * rather than deliver a hole nothing could report: the daemon likewise kills a connection instead
 * of skipping a frame whose loss no receiver could detect. Resync, as for a `GapError`.
 */
export class BacklogError extends Error {
    name = "BacklogError";
    /** How many events were queued for this consumer when the stream was ended. */
    backlog;
    /** Built by the client when one consumer cannot keep up with the connection. */
    constructor(backlog) {
        super(`broadcast consumer fell ${backlog} events behind; resync required`);
        this.backlog = backlog;
    }
}
/** The connection closed. */
export class ClosedError extends Error {
    name = "ClosedError";
    /** WebSocket close code, or 0 when the client closed locally. */
    code;
    /** Built by the client when the connection ends. */
    constructor(code, reason) {
        super(reason === "" ? `connection closed (${code})` : `connection closed (${code}): ${reason}`);
        this.code = code;
    }
}
//# sourceMappingURL=errors.js.map