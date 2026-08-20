import { DELTA_FIELDS, DELIVERY_CLASS, DELIVERY_RULES, SEQ_FIELD, SESSION_FIELD } from "./generated/broadcasts.js";
import {} from "./generated/methods.js";
import { CONSTANTS, LIMITS, PROTOCOL_VERSION, STRING_CONSTANTS } from "./generated/limits.js";
import { BacklogError, ClosedError, GapError, ProtocolError, RpcError } from "./errors.js";
import { WebSocketTransport } from "./transport.js";
import { assertBroadcast, assertParams, assertResult, WireValidationError } from "./validate.js";
import { scanEnvelope } from "./json-scan.js";
const JSONRPC = STRING_CONSTANTS.JSONRPC_VERSION;
// One encoder for the whole client: offsets are measured on every delta frame, and a new
// TextEncoder per frame is pure allocation.
const UTF8 = new TextEncoder();
/**
 * A connected client.
 *
 * Holds the four obligations the protocol places on a receiver: `initialize` before anything else,
 * responses correlated by id (and remembered by method, since a result is not self-describing),
 * sequenced broadcasts gap-checked, and shed droppable deltas detected by offset.
 */
export class Client {
    #transport;
    #pending = new Map();
    #nextId = 1;
    #closed;
    #queues = new Set();
    #seq = new Map();
    // Keyed by session, holding only the active draft: a session has one, so an older message id
    // can no longer receive deltas and its offsets are dead weight.
    #offsets = new Map();
    #initializeResult;
    #options;
    constructor(transport, options) {
        this.#transport = transport;
        this.#options = options;
        transport.onmessage = (frame) => this.#receive(frame);
        transport.onclose = (info) => this.#onClosed(new ClosedError(info.code, info.reason));
        transport.onerror = (error) => this.#onClosed(new ClosedError(0, error.message));
    }
    /** Connect and complete the handshake. No other request is accepted before this resolves. */
    static async connect(url, options) {
        const transport = options.transport ?? new WebSocketTransport(url);
        const client = new Client(transport, options);
        await transport.start();
        try {
            client.#initializeResult = await client.#send("initialize", {
                protocol: PROTOCOL_VERSION,
                client: options.client,
            });
        }
        catch (error) {
            // The socket is open but unusable: nothing may be sent before a successful handshake, and
            // the caller has no client object to close it with.
            transport.close();
            throw error;
        }
        return client;
    }
    /** Whether a request other than `initialize` may be sent. */
    get #ready() {
        return this.#initializeResult !== undefined && this.#closed === undefined;
    }
    /** What the daemon reported during the handshake. */
    get initializeResult() {
        if (this.#initializeResult === undefined)
            throw new ProtocolError("the handshake has not completed");
        return this.#initializeResult;
    }
    /** Send a request and await its typed result. */
    async request(method, ...args) {
        if (!this.#ready)
            throw new ProtocolError(`initialize must complete before ${method}`);
        const [params, options = {}] = args;
        return this.#send(method, params, options.signal);
    }
    /**
     * The broadcast stream, as an async iterable. Several consumers may iterate at once; each gets
     * every event from the moment it started.
     */
    broadcasts(options = {}) {
        const queue = new BroadcastQueue();
        this.#queues.add(queue);
        queue.onRelease(() => this.#queues.delete(queue));
        if (this.#closed !== undefined)
            queue.fail(this.#closed);
        // Dropped when the queue is released, so a signal that outlives the iteration — one
        // controller for the whole application, say — does not accumulate a listener per call.
        const onAbort = () => queue.finish();
        options.signal?.addEventListener("abort", onAbort, { once: true });
        queue.onRelease(() => options.signal?.removeEventListener("abort", onAbort));
        return queue.iterator();
    }
    /** Close the connection and reject anything in flight. */
    close() {
        this.#transport.close();
        this.#onClosed(new ClosedError(0, "closed by the client"));
    }
    /** Closes the client, so it works with `await using` on runtimes that parse it. */
    async [Symbol.asyncDispose]() {
        this.close();
    }
    // --- internals ----------------------------------------------------------------------
    #send(method, params, signal) {
        if (this.#closed !== undefined)
            return Promise.reject(this.#closed);
        try {
            assertParams(method, params);
        }
        catch (error) {
            return Promise.reject(error);
        }
        const id = this.#nextId++;
        if (id > CONSTANTS.MAX_REQUEST_ID) {
            return Promise.reject(new ProtocolError("ran out of correlation ids for this connection"));
        }
        return new Promise((resolve, reject) => {
            if (signal?.aborted === true) {
                reject(signal.reason instanceof Error ? signal.reason : new Error("aborted"));
                return;
            }
            const onAbort = () => {
                // The id stays reserved: a late response must still be matched and discarded rather than
                // mistaken for another request's result.
                this.#pending.delete(id);
                reject(signal?.reason instanceof Error ? signal.reason : new Error("aborted"));
            };
            signal?.addEventListener("abort", onAbort, { once: true });
            this.#pending.set(id, {
                method,
                resolve: resolve,
                reject,
                onSettled: () => signal?.removeEventListener("abort", onAbort),
            });
            try {
                const request = params === undefined ? { jsonrpc: JSONRPC, id, method } : { jsonrpc: JSONRPC, id, method, params };
                this.#transport.send(JSON.stringify(request));
            }
            catch (error) {
                this.#pending.delete(id);
                signal?.removeEventListener("abort", onAbort);
                reject(error instanceof Error ? error : new Error(String(error)));
            }
        });
    }
    #receive(frame) {
        const bytes = UTF8.encode(frame).byteLength;
        if (bytes > LIMITS.max_frame_bytes) {
            this.#fail(new ProtocolError(`the daemon sent a ${bytes}-byte frame over the ${LIMITS.max_frame_bytes}-byte cap`));
            return;
        }
        let envelope;
        try {
            envelope = scanEnvelope(frame);
        }
        catch {
            this.#fail(new ProtocolError("the daemon sent a frame that is not JSON"));
            return;
        }
        // Unknown notifications are deliberately skipped after validating their JSON structure and
        // envelope. Their payload may belong to a newer protocol and must not be materialized.
        if (!envelope.hasId && envelope.method !== undefined && !(envelope.method in DELIVERY_CLASS)) {
            if (envelope.jsonrpc !== JSONRPC) {
                this.#fail(new ProtocolError(`frame carries jsonrpc ${String(envelope.jsonrpc)}`));
                return;
            }
            this.#options.onUnknown?.(envelope.method);
            return;
        }
        let parsed;
        try {
            parsed = JSON.parse(frame);
        }
        catch {
            this.#fail(new ProtocolError("the daemon sent a frame that is not JSON"));
            return;
        }
        if (typeof parsed !== "object" || parsed === null) {
            this.#fail(new ProtocolError("the daemon sent a frame that is not a JSON object"));
            return;
        }
        const message = parsed;
        if (message["jsonrpc"] !== JSONRPC) {
            this.#fail(new ProtocolError(`frame carries jsonrpc ${String(message["jsonrpc"])}`));
            return;
        }
        // A notification has no id; a response must have one. Routing on that is what the wire does.
        if (message["id"] === undefined) {
            this.#dispatchBroadcast(message);
            return;
        }
        this.#settle(message);
    }
    #settle(message) {
        const id = message["id"];
        if (typeof id !== "number") {
            this.#fail(new ProtocolError("a response carries an id this client never issued"));
            return;
        }
        const pending = this.#pending.get(id);
        if (pending === undefined) {
            // An id we abandoned on abort, or one we never sent. Neither is fatal.
            return;
        }
        this.#pending.delete(id);
        pending.onSettled();
        const error = message["error"];
        if (error !== undefined) {
            const detail = error;
            const code = typeof detail.code === "number" ? detail.code : 0;
            const text = typeof detail.message === "string" ? detail.message : "request failed";
            pending.reject(RpcError.from(code, text));
            return;
        }
        if (!("result" in message)) {
            pending.reject(new ProtocolError(`response to ${pending.method} carried neither result nor error`));
            return;
        }
        // `pending.method` is what makes this typed: the frame itself does not say.
        try {
            assertResult(pending.method, message["result"]);
        }
        catch (error) {
            const protocol = new ProtocolError(error instanceof Error ? error.message : String(error));
            pending.reject(protocol);
            this.#fail(protocol);
            return;
        }
        pending.resolve(message["result"]);
    }
    #dispatchBroadcast(message) {
        const method = message["method"];
        if (typeof method !== "string") {
            this.#fail(new ProtocolError("a notification carries no method"));
            return;
        }
        if (!(method in DELIVERY_CLASS)) {
            this.#options.onUnknown?.(method);
            return;
        }
        const name = method;
        const cls = DELIVERY_CLASS[name];
        const params = message["params"];
        try {
            assertBroadcast(method, params);
        }
        catch (error) {
            this.#fail(new ProtocolError(error instanceof WireValidationError ? error.message : `${method} carries invalid params`));
            return;
        }
        this.#checkDelivery(name, cls, params);
        const event = { method: name, params, class: cls };
        for (const queue of this.#queues)
            queue.push(event);
    }
    /**
     * Gap detection. Which checks apply comes from the artifact's delivery rules rather than from
     * anything hardcoded here, so a new class or a reclassified broadcast changes behaviour by
     * regenerating.
     */
    #checkDelivery(name, cls, params) {
        const sessionField = SESSION_FIELD[name];
        const session = sessionField === undefined ? undefined : params[sessionField];
        if (typeof session !== "string")
            return;
        // The per-broadcast sequence field is the precise form of the class-level `sequenced` rule:
        // the artifact marks a class sequenced exactly when its broadcasts carry one.
        const field = SEQ_FIELD[name];
        const seq = field === undefined ? undefined : params[field];
        if (typeof seq === "number") {
            const last = this.#seq.get(session);
            if (last !== undefined && seq !== last + 1) {
                this.#gap(new GapError(session, name, last + 1, seq, "sequence"));
            }
            this.#seq.set(session, seq);
        }
        if (!DELIVERY_RULES[cls].droppable)
            return;
        // A shed frame shows up as a delta that does not continue where the last one ended. Each
        // member of the key must be the type the protocol gives it, or two different parts could
        // compare as one.
        const fields = DELTA_FIELDS[name];
        if (fields === undefined) {
            // Droppable without stream roles is a shed *marker*: the frame itself proves loss.
            // `received` carries a positive shed count when the payload has one; else 0.
            const count = params.count;
            this.#gap(new GapError(session, name, 0, typeof count === "number" ? count : 0, "shed"));
            return;
        }
        const offset = params[fields.offset];
        const delta = params[fields.chunk];
        const messageId = params[fields.draft];
        const partId = params[fields.part];
        if (typeof offset !== "number" || typeof delta !== "string")
            return;
        if (typeof messageId !== "number" || typeof partId !== "number")
            return;
        // Offsets are per stream, not per part. `tool.output_delta` folds into a tool part's output
        // while `message.part_delta` folds into the same part's content, and each counts from zero —
        // one shared counter would read the second stream's first frame as a gap.
        const key = `${name}:${partId}`;
        let draft = this.#offsets.get(session);
        // Only the newest draft can still receive deltas, so an older message id is a straggler whose
        // baseline is already gone. Replacing the draft is also what keeps this map from growing.
        if (draft !== undefined && messageId < draft.messageId)
            return;
        if (draft === undefined || draft.messageId !== messageId) {
            draft = { messageId, parts: new Map() };
            this.#offsets.set(session, draft);
        }
        const expected = draft.parts.get(key);
        if (expected !== undefined && offset !== expected) {
            this.#gap(new GapError(session, name, expected, offset, "offset"));
            // `#gap` drops the session's tracking; this frame re-establishes the baseline, so one shed
            // delta does not report again on every frame after it.
            draft = { messageId, parts: new Map() };
            this.#offsets.set(session, draft);
        }
        // Offsets count UTF-8 bytes, not code units, so the advance is measured in bytes.
        draft.parts.set(key, offset + UTF8.encode(delta).byteLength);
    }
    #gap(gap) {
        // Dropping our own tracking for the session: the next frame re-establishes a baseline, so a
        // single gap does not produce a gap report per subsequent frame.
        this.#seq.delete(gap.sessionId);
        this.#offsets.delete(gap.sessionId);
        this.#options.onGap?.(gap);
    }
    #fail(error) {
        this.#transport.close();
        this.#onClosed(new ClosedError(0, error.message));
    }
    #onClosed(error) {
        if (this.#closed !== undefined)
            return;
        this.#closed = error;
        for (const [, pending] of this.#pending) {
            pending.onSettled();
            pending.reject(error);
        }
        this.#pending.clear();
        for (const queue of this.#queues)
            queue.fail(error);
        this.#options.onClose?.(error);
    }
}
/**
 * How many events one consumer may fall behind by. A client-side backpressure choice, not a
 * protocol limit: the wire says nothing about how fast a receiver reads.
 */
export const BROADCAST_BACKLOG = 1024;
/** Bridges pushed events to an async iterator, buffering while no one is awaiting. */
class BroadcastQueue {
    #buffer = [];
    // FIFO: concurrent next() calls each get their own slot. A single slot would let the second
    // overwrite the first, leaving that promise to never settle.
    #waiters = [];
    #error;
    #done = false;
    #release = [];
    /** Run `fn` once the queue stops delivering, however it stops. */
    onRelease(fn) {
        if (this.#done) {
            fn();
            return;
        }
        this.#release.push(fn);
    }
    push(event) {
        // A queue holding a terminal error delivers what it already buffered and nothing more.
        if (this.#done || this.#error !== undefined)
            return;
        const waiter = this.#waiters.shift();
        if (waiter !== undefined) {
            waiter.resolve({ value: event, done: false });
            return;
        }
        // Ending the stream rather than dropping the oldest event: the gap check already ran, so a
        // dropped event is a hole no offset or seq could report. The daemon makes the same call when
        // its send queue fills — shed only what the receiver can detect, otherwise sever.
        if (this.#buffer.length >= BROADCAST_BACKLOG) {
            this.fail(new BacklogError(this.#buffer.length));
            return;
        }
        this.#buffer.push(event);
    }
    /** End the stream with `error`, after whatever is already buffered has been read. */
    fail(error) {
        if (this.#done)
            return;
        this.#error = error;
        const waiters = this.#waiters.splice(0);
        this.#finish();
        for (const waiter of waiters)
            waiter.reject(error);
    }
    finish() {
        const waiters = this.#waiters.splice(0);
        this.#finish();
        for (const waiter of waiters)
            waiter.resolve({ value: undefined, done: true });
    }
    #finish() {
        if (this.#done)
            return;
        this.#done = true;
        for (const fn of this.#release)
            fn();
        this.#release.length = 0;
    }
    iterator() {
        const self = this;
        return {
            [Symbol.asyncIterator]() {
                return this;
            },
            next() {
                const buffered = self.#buffer.shift();
                if (buffered !== undefined)
                    return Promise.resolve({ value: buffered, done: false });
                if (self.#error !== undefined) {
                    const error = self.#error;
                    self.#finish();
                    return Promise.reject(error);
                }
                if (self.#done)
                    return Promise.resolve({ value: undefined, done: true });
                return new Promise((resolve, reject) => {
                    self.#waiters.push({ resolve, reject });
                });
            },
            return() {
                self.finish();
                return Promise.resolve({ value: undefined, done: true });
            },
        };
    }
}
//# sourceMappingURL=client.js.map