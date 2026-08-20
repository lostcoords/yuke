// Owned client-side projection of one session's transcript, ported from the canonical
// yuke daemon reference `src/client/session_replica.odin`. It folds live broadcasts and
// atomically installs resync snapshots; synchronization (dropping broadcasts while a
// resync is in flight, then installing the ordered response barrier) belongs to the
// controller that drives it, not here.
//
// This is the single owner of fold + gap detection: `applyBroadcast` gates durable events
// on the per-session sequence and reports a discontinuity as `{ kind: "gap" }`, on which
// the controller must `session.resync` and `installSnapshot` the result.
//
// Differences from the Odin original, all mechanical: garbage collection removes the arena
// bookkeeping, per-object clones, and the transactional-free dance; the session-id check is
// done once at dispatch instead of in every handler; config equality goes through
// `runConfigEqual` so a new `RunConfig` field can't silently escape the conflict check.
import { LIMITS } from "./generated/limits.js";
// Largest committed window retained live; older messages fall off.
const MAX_RETAINED_MESSAGES = LIMITS.max_page_size;
const ENCODER = /* @__PURE__ */ new TextEncoder();
// UTF-8 byte length of a string. Offsets in the wire delta contract are UTF-8 bytes, never
// UTF-16 code units, so every buffer length compared against an `offset` is measured here.
function utf8Len(s) {
    return ENCODER.encode(s).length;
}
// A wire ordinal usable as a collection index, or null if it is not a non-negative integer.
function asIndex(v) {
    return Number.isInteger(v) && v >= 0 ? v : null;
}
/** Thrown by {@link SessionReplica.applyBroadcast} (config conflict) and
 * {@link SessionReplica.installSnapshot} (session mismatch, malformed snapshot). These are
 * hard protocol breaks, distinct from a recoverable `gap`. */
export class ReplicaError extends Error {
    code;
    constructor(code, message) {
        super(message);
        this.name = "ReplicaError";
        this.code = code;
    }
}
const IGNORED = { kind: "ignored" };
const GAP = { kind: "gap" };
const CHANGED = { kind: "changed" };
// A terminal tool state never transitions back to an active state.
function toolStateIsTerminal(state) {
    switch (state.type) {
        case "completed":
        case "error":
        case "denied":
        case "canceled":
            return true;
        default:
            return false;
    }
}
// A waiting-permission state is still eligible for a decision when it has no decision yet
// and carries options to decide among.
function permissionStateIsAwaiting(state) {
    if (state.decision !== undefined) {
        return false;
    }
    return state.options !== undefined;
}
// The ordinal an assistant part stores.
function assistantPartId(part) {
    return part.id;
}
// Content model fields differ only in whether the mutable field set is currently the same
// as the last-seen config; centralized so a new RunConfig field can't slip past the
// conflict check unnoticed (odin compared model/reasoning inline).
function runConfigEqual(a, b) {
    return a.model === b.model && a.reasoning === b.reasoning;
}
// Build one active-draft part from a wire assistant part. A tool part's output buffer starts
// empty; a caller seeding it from a running tool's snapshot output does so after this returns.
function activePartFromWire(part) {
    switch (part.type) {
        case "text":
            return { kind: "text", text: { id: part.id, text: part.text, byteLen: utf8Len(part.text) } };
        case "reasoning":
            return { kind: "reasoning", text: { id: part.id, text: part.text, byteLen: utf8Len(part.text) } };
        case "redacted_reasoning":
            return { kind: "redacted_reasoning", redacted: { id: part.id, data: part.data } };
        case "tool":
            return { kind: "tool", tool: { tool: { ...part }, output: "", outputByteLen: 0 } };
    }
}
// The ordinal an already-built active part stores.
function activePartOrdinal(part) {
    switch (part.kind) {
        case "tool":
            return part.tool.tool.id;
        case "redacted_reasoning":
            return part.redacted.id;
        case "text":
        case "reasoning":
            return part.text.id;
    }
}
// Whether another tool in `draft` is waiting for permission. `except` excludes the part
// being transitioned in place.
function draftHasWaitingPermission(draft, except) {
    for (const part of draft.parts) {
        if (part.kind !== "tool") {
            continue;
        }
        if (except !== null && part.tool.tool.id === except) {
            continue;
        }
        if (part.tool.tool.state.type === "waiting_permission") {
            return true;
        }
    }
    return false;
}
export class SessionReplica {
    sessionId;
    #active = null;
    // High-water mark of committed or discarded ids; lower ids are finalized.
    #highestFinalizedId = null;
    #baseSeq = 0;
    // Committed window, oldest first, unique by id.
    #messages = [];
    #hasMore = false;
    // Immutable configs keyed by revision.
    #configs = new Map();
    #pendingCompaction = null;
    // Run id most recently cleared by a durable run.done / compaction start. Run ids are never
    // reused, so a stale `session.activity` re-asserting this id can be recognized and dropped.
    #lastClearedCompaction = null;
    #queued = [];
    constructor(sessionId) {
        this.sessionId = sessionId;
    }
    // --- read-side views ---
    get baseSeq() {
        return this.#baseSeq;
    }
    get hasMore() {
        return this.#hasMore;
    }
    get highestFinalizedId() {
        return this.#highestFinalizedId;
    }
    get pendingCompaction() {
        return this.#pendingCompaction;
    }
    /** Committed messages, oldest first. */
    get messages() {
        return this.#messages;
    }
    /** Inputs queued behind the active turn. */
    get queued() {
        return this.#queued;
    }
    /** Active draft metadata, or null when no draft is open. */
    activeInfo() {
        const d = this.#active;
        if (d === null) {
            return null;
        }
        return {
            message_id: d.message_id,
            run_id: d.run_id,
            config_rev: d.config_rev,
            agent: d.agent,
            created_at_ms: d.created_at_ms,
            part_count: d.parts.length,
        };
    }
    /** A part's kind, or null if the part is absent. */
    partKind(partId) {
        const part = this.#partAt(partId);
        return part === null ? null : part.kind;
    }
    /** Accumulated text/reasoning bytes, or null for a redacted, tool, or absent part. */
    partText(partId) {
        const part = this.#partAt(partId);
        if (part === null || (part.kind !== "text" && part.kind !== "reasoning")) {
            return null;
        }
        return part.text.text;
    }
    /** Opaque redacted-reasoning payload, or null for any other or absent part. */
    redactedPart(partId) {
        const part = this.#partAt(partId);
        if (part === null || part.kind !== "redacted_reasoning") {
            return null;
        }
        return part.redacted;
    }
    /** The complete active tool part, or null for a non-tool or absent part. */
    toolPart(partId) {
        const part = this.#partAt(partId);
        if (part === null || part.kind !== "tool") {
            return null;
        }
        return part.tool.tool;
    }
    /** Display output streamed so far for a tool part, or null for a non-tool or absent part. */
    toolOutput(partId) {
        const part = this.#partAt(partId);
        if (part === null || part.kind !== "tool") {
            return null;
        }
        return part.tool.output;
    }
    /** The tool call awaiting permission, or null when none is. */
    pendingPermission() {
        const draft = this.#active;
        if (draft === null) {
            return null;
        }
        for (const part of draft.parts) {
            if (part.kind !== "tool") {
                continue;
            }
            const tool = part.tool.tool;
            if (tool.state.type !== "waiting_permission") {
                continue;
            }
            const perm = tool.permission_state;
            if (perm === undefined || !permissionStateIsAwaiting(perm)) {
                continue;
            }
            const options = perm.options;
            if (options === undefined) {
                continue;
            }
            return {
                message_id: draft.message_id,
                part_id: tool.id,
                tool_name: tool.name,
                arguments: tool.arguments,
                options,
                requested_at_ms: perm.requested_at_ms,
            };
        }
        return null;
    }
    /** A committed message by id, or null if absent. */
    committedById(id) {
        for (const m of this.#messages) {
            if (m.id === id) {
                return m;
            }
        }
        return null;
    }
    /** A config by revision, or null if absent. */
    config(configRev) {
        return this.#configs.get(configRev) ?? null;
    }
    // --- fold entry point ---
    /** Fold one session-scoped broadcast. Foreign-session and non-folded broadcasts are
     * ignored. A `gap` result leaves the replica unchanged and tells the controller to
     * `session.resync`. Throws {@link ReplicaError} only on a hard protocol break (config
     * revision conflict). */
    applyBroadcast(bc) {
        switch (bc.method) {
            // Durable, sequence-gated events.
            case "message.committed": {
                const p = bc.params;
                const gate = this.#gateDurable(p.session_id, p.seq);
                if (gate !== null) {
                    return gate;
                }
                const r = this.#onCommitted(p.message);
                this.#baseSeq = p.seq;
                return r;
            }
            case "config.changed": {
                const p = bc.params;
                const gate = this.#gateDurable(p.session_id, p.seq);
                if (gate !== null) {
                    return gate;
                }
                const r = this.#onConfigChanged(p.config); // may throw on conflict, before base_seq advances
                this.#baseSeq = p.seq;
                return r;
            }
            case "transcript.truncated": {
                const p = bc.params;
                const gate = this.#gateDurable(p.session_id, p.seq);
                if (gate !== null) {
                    return gate;
                }
                const r = this.#onTruncated(p.first_removed_id);
                this.#baseSeq = p.seq;
                return r;
            }
            case "run.done": {
                const p = bc.params;
                const gate = this.#gateDurable(p.session_id, p.seq);
                if (gate !== null) {
                    return gate;
                }
                // Run_Done covers every outcome and clears a pending compaction keyed by the run.
                const r = this.#clearPendingCompaction(p.run_id);
                this.#baseSeq = p.seq;
                return r;
            }
            case "run.started": {
                const p = bc.params;
                const gate = this.#gateDurable(p.session_id, p.seq);
                if (gate !== null) {
                    return gate;
                }
                // Only a compaction run's start clears the queued compaction; a turn run just
                // advances the sequence.
                const r = p.kind === "compaction" ? this.#clearPendingCompaction(p.run_id) : IGNORED;
                this.#baseSeq = p.seq;
                return r;
            }
            // Live, unsequenced draft lifecycle.
            case "message.started":
                return this.#sameSession(bc.params.session_id) ? this.#onStarted(bc.params) : IGNORED;
            case "message.part_added":
                return this.#sameSession(bc.params.session_id) ? this.#onPartAdded(bc.params.message_id, bc.params.part) : IGNORED;
            case "message.part_delta":
                return this.#sameSession(bc.params.session_id) ? this.#onPartDelta(bc.params) : IGNORED;
            case "tool.state_changed":
                return this.#sameSession(bc.params.session_id) ? this.#onToolStateChanged(bc.params) : IGNORED;
            case "tool.output_delta":
                return this.#sameSession(bc.params.session_id) ? this.#onToolOutputDelta(bc.params) : IGNORED;
            case "message.discarded":
                return this.#sameSession(bc.params.session_id) ? this.#onDiscarded(bc.params.message_id) : IGNORED;
            case "input.queued":
                return this.#sameSession(bc.params.session_id) ? this.#onInputQueued(bc.params.input) : IGNORED;
            case "input.canceled":
                return this.#sameSession(bc.params.session_id) ? this.#onInputCanceled(bc.params.input_id) : IGNORED;
            case "session.activity_changed":
                return this.#sameSession(bc.params.session_id) ? this.#onActivityChanged(bc.params.activity.state, bc.params.activity.pending_compaction) : IGNORED;
            default:
                // Every other broadcast is foreign-domain and never folded.
                return IGNORED;
        }
    }
    // --- resync install ---
    /** Install a validated resync cut transactionally: prior state is untouched until the
     * candidate is fully built. Throws {@link ReplicaError} on session mismatch or a malformed
     * snapshot. */
    installSnapshot(r) {
        if (r.item.session.id !== this.sessionId) {
            throw new ReplicaError("session_mismatch", "resync snapshot is for a different session");
        }
        if (r.messages.length > MAX_RETAINED_MESSAGES) {
            throw new ReplicaError("malformed_snapshot", "resync snapshot exceeds the retained window");
        }
        // Committed window must be strictly increasing and unique by id.
        for (let i = 1; i < r.messages.length; i += 1) {
            if (r.messages[i].id <= r.messages[i - 1].id) {
                throw new ReplicaError("malformed_snapshot", "resync messages are not strictly increasing by id");
            }
        }
        // Build candidates. Nothing below touches `this` until every fallible step has passed.
        const active = r.active !== undefined ? this.#draftFromSnapshot(r.active) : null;
        const configs = new Map();
        for (const cfg of r.configs) {
            configs.set(cfg.config_rev, cfg);
        }
        // Commit.
        this.#messages = [...r.messages];
        this.#queued = [...r.queued];
        this.#configs = configs;
        this.#active = active;
        this.#baseSeq = r.base_seq;
        this.#hasMore = r.has_more;
        this.#highestFinalizedId = r.highest_finalized_message_id;
        this.#pendingCompaction = r.item.activity.pending_compaction;
        this.#lastClearedCompaction = null;
    }
    // --- durable folding ---
    // Gate a durable event on the per-session sequence: null means "apply", otherwise the
    // short-circuit result. The caller advances base_seq only after a successful apply.
    #gateDurable(sessionId, seq) {
        if (sessionId !== this.sessionId) {
            return IGNORED;
        }
        if (seq <= this.#baseSeq) {
            return IGNORED; // stale, already represented
        }
        if (seq > this.#baseSeq + 1) {
            return GAP; // missed a durable event
        }
        return null;
    }
    #onCommitted(message) {
        const mid = message.id;
        let inserted = false;
        for (let i = 0; i < this.#messages.length; i += 1) {
            const existingId = this.#messages[i].id;
            if (existingId === mid) {
                this.#messages[i] = message; // replace in place
                inserted = true;
                break;
            }
            if (existingId > mid) {
                this.#messages.splice(i, 0, message); // keep oldest-first order
                this.#evictOldestIfFull();
                inserted = true;
                break;
            }
        }
        if (!inserted) {
            this.#messages.push(message); // newest
            this.#evictOldestIfFull();
        }
        this.#advanceFinalized(mid);
        // Only a committed user message dequeues its accepted input.
        if (message.type === "user") {
            const inputId = message.input_id;
            const qi = this.#queued.findIndex((q) => q.input_id === inputId);
            if (qi >= 0) {
                this.#queued.splice(qi, 1);
            }
        }
        // Clear only the draft this commit finalizes.
        if (this.#active !== null && this.#active.message_id === mid) {
            this.#active = null;
        }
        return { kind: "committed", message_id: mid };
    }
    #onConfigChanged(config) {
        const existing = this.#configs.get(config.config_rev);
        if (existing !== undefined) {
            if (!runConfigEqual(existing, config)) {
                throw new ReplicaError("config_revision_conflict", `config_rev ${config.config_rev} reappeared with different content`);
            }
            return IGNORED;
        }
        this.#configs.set(config.config_rev, config);
        return CHANGED;
    }
    #onTruncated(firstRemovedId) {
        let changed = false;
        // Drop committed messages at or above the cut. `highestFinalizedId` is deliberately NOT
        // lowered: ids above the boundary are retired via the high-water mark and never reused
        // (daemon invariant), so a later draft can only carry a strictly higher id.
        for (let i = this.#messages.length - 1; i >= 0; i -= 1) {
            if (this.#messages[i].id >= firstRemovedId) {
                this.#messages.splice(i, 1);
                changed = true;
            }
        }
        return changed ? CHANGED : IGNORED;
    }
    #clearPendingCompaction(runId) {
        if (this.#pendingCompaction !== null && this.#pendingCompaction === runId) {
            this.#pendingCompaction = null;
            this.#lastClearedCompaction = runId;
            return CHANGED;
        }
        return IGNORED;
    }
    // --- live folding ---
    #onStarted(data) {
        if (this.#isFinalized(data.message_id)) {
            return IGNORED;
        }
        if (this.#active !== null) {
            return this.#active.message_id === data.message_id ? IGNORED : GAP;
        }
        this.#active = {
            message_id: data.message_id,
            run_id: data.run_id,
            config_rev: data.config_rev,
            agent: data.agent,
            created_at_ms: data.created_at_ms,
            parts: [],
        };
        return CHANGED;
    }
    #onPartAdded(messageId, part) {
        const draft = this.#openDraft(messageId);
        if (draft === null) {
            return this.#isFinalized(messageId) ? IGNORED : GAP;
        }
        const ordinal = assistantPartId(part);
        const count = draft.parts.length;
        if (ordinal < count) {
            return IGNORED; // duplicated
        }
        if (ordinal > count) {
            return GAP; // missing part
        }
        if (part.type === "tool" && part.state.type === "waiting_permission" && draftHasWaitingPermission(draft, null)) {
            return GAP;
        }
        draft.parts.push(activePartFromWire(part));
        return CHANGED;
    }
    #onPartDelta(data) {
        const draft = this.#openDraft(data.message_id);
        if (draft === null) {
            return this.#isFinalized(data.message_id) ? IGNORED : GAP;
        }
        const index = asIndex(data.part_id);
        if (index === null || index >= draft.parts.length) {
            return GAP;
        }
        const part = draft.parts[index];
        if (part.kind !== "text" && part.kind !== "reasoning") {
            return GAP;
        }
        const offset = asIndex(data.offset);
        if (offset === null) {
            return GAP;
        }
        const have = part.text.byteLen;
        if (offset < have) {
            return IGNORED; // already present
        }
        if (offset > have) {
            return GAP; // missed a delta
        }
        part.text.text += data.delta;
        part.text.byteLen += utf8Len(data.delta);
        return CHANGED;
    }
    #onToolOutputDelta(data) {
        const draft = this.#openDraft(data.message_id);
        if (draft === null) {
            return this.#isFinalized(data.message_id) ? IGNORED : GAP;
        }
        const index = asIndex(data.part_id);
        if (index === null || index >= draft.parts.length) {
            return GAP;
        }
        const part = draft.parts[index];
        if (part.kind !== "tool") {
            return GAP;
        }
        // Output streams only while running; a delta for a terminal tool is a straggler whose
        // output is already final, so it is ignored rather than resynced.
        if (part.tool.tool.state.type !== "running") {
            return IGNORED;
        }
        const offset = asIndex(data.offset);
        if (offset === null) {
            return GAP;
        }
        const have = part.tool.outputByteLen;
        if (offset < have) {
            return IGNORED;
        }
        if (offset > have) {
            return GAP;
        }
        // Exceeding the daemon's cap is a protocol violation, recovered via the same resync path.
        if (have + utf8Len(data.delta) > LIMITS.max_tool_output_stream_bytes) {
            return GAP;
        }
        part.tool.output += data.delta;
        part.tool.outputByteLen += utf8Len(data.delta);
        return CHANGED;
    }
    #onToolStateChanged(data) {
        const draft = this.#openDraft(data.message_id);
        if (draft === null) {
            return this.#isFinalized(data.message_id) ? IGNORED : GAP;
        }
        const index = asIndex(data.part_id);
        if (index === null || index >= draft.parts.length) {
            return GAP;
        }
        const part = draft.parts[index];
        if (part.kind !== "tool") {
            return GAP;
        }
        // A stale broadcast must not regress a terminal tool part back to an active state.
        if (toolStateIsTerminal(part.tool.tool.state) && !toolStateIsTerminal(data.state)) {
            return IGNORED;
        }
        if (data.state.type === "waiting_permission") {
            const perm = data.permission_state;
            // A resolution must not leave the state in waiting_permission.
            if (perm === undefined || !permissionStateIsAwaiting(perm)) {
                return GAP;
            }
            if (draftHasWaitingPermission(draft, data.part_id)) {
                return GAP;
            }
        }
        // Replace tool state wholesale; permission_state is replaced when present, else cleared.
        // Destructure the old permission_state out so the cleared case omits the key entirely
        // (exactOptionalPropertyTypes forbids an explicit `undefined`).
        const { permission_state: _prev, ...rest } = part.tool.tool;
        part.tool.tool = data.permission_state === undefined
            ? { ...rest, state: data.state }
            : { ...rest, state: data.state, permission_state: data.permission_state };
        return CHANGED;
    }
    #onDiscarded(messageId) {
        if (this.#active !== null && this.#active.message_id === messageId) {
            this.#advanceFinalized(messageId);
            this.#active = null;
            return { kind: "discarded", message_id: messageId };
        }
        return IGNORED;
    }
    #onInputQueued(input) {
        for (const q of this.#queued) {
            if (q.input_id === input.input_id) {
                return IGNORED;
            }
        }
        this.#queued.push(input);
        return CHANGED;
    }
    #onInputCanceled(inputId) {
        const i = this.#queued.findIndex((q) => q.input_id === inputId);
        if (i >= 0) {
            this.#queued.splice(i, 1);
            return CHANGED;
        }
        return IGNORED;
    }
    #onActivityChanged(state, pendingCompaction) {
        if (this.#activityLocatorsDiverge(state)) {
            return GAP;
        }
        let incoming = pendingCompaction;
        // A stale activity must not re-assert a compaction a durable run.done already cleared.
        if (incoming !== null && this.#lastClearedCompaction !== null && incoming === this.#lastClearedCompaction) {
            incoming = null;
        }
        if (this.#pendingCompaction === incoming) {
            return IGNORED;
        }
        this.#pendingCompaction = incoming;
        return CHANGED;
    }
    // --- helpers ---
    #sameSession(sessionId) {
        return sessionId === this.sessionId;
    }
    #openDraft(messageId) {
        if (this.#active !== null && this.#active.message_id === messageId) {
            return this.#active;
        }
        return null;
    }
    #isFinalized(messageId) {
        return this.#highestFinalizedId !== null && messageId <= this.#highestFinalizedId;
    }
    #advanceFinalized(messageId) {
        if (this.#highestFinalizedId === null || messageId > this.#highestFinalizedId) {
            this.#highestFinalizedId = messageId;
        }
    }
    // Evict the oldest committed message once the window exceeds the retained page, marking
    // that older history exists.
    #evictOldestIfFull() {
        if (this.#messages.length > MAX_RETAINED_MESSAGES) {
            this.#messages.shift();
            this.#hasMore = true;
        }
    }
    #partAt(partId) {
        if (this.#active === null) {
            return null;
        }
        const index = asIndex(partId);
        if (index === null || index >= this.#active.parts.length) {
            return null;
        }
        return this.#active.parts[index];
    }
    // The draft part an activity locator names, or null when the replica cannot compare
    // against it: no draft for that message, or an ordinal it has not folded yet.
    #locatedPart(messageId, partId) {
        if (this.#openDraft(messageId) === null) {
            return null;
        }
        const part = this.#partAt(partId);
        if (part === null || activePartOrdinal(part) !== partId) {
            return null;
        }
        return part;
    }
    // True when an activity's locators contradict the replica's own derived draft state. Only
    // an identity conflict at a part the replica already holds proves divergence.
    #activityLocatorsDiverge(state) {
        switch (state.type) {
            case "reasoning": {
                const part = this.#locatedPart(state.message_id, state.part_id);
                return part !== null && part.kind !== "reasoning";
            }
            case "waiting_permission": {
                const part = this.#locatedPart(state.message_id, state.part_id);
                return part !== null && (part.kind !== "tool" || part.tool.tool.name !== state.tool_name);
            }
            case "running_tool": {
                const part = this.#locatedPart(state.message_id, state.part_id);
                return part !== null && (part.kind !== "tool" || part.tool.tool.name !== state.tool_name);
            }
            default:
                return false;
        }
    }
    // Reconstruct a mid-flight draft from a resync snapshot so subsequent deltas resume at the
    // right offset. A part whose ordinal does not equal its index is a malformed snapshot.
    #draftFromSnapshot(src) {
        const msg = src.message;
        const parts = [];
        for (let index = 0; index < msg.content.length; index += 1) {
            const wirePart = msg.content[index];
            const ord = asIndex(assistantPartId(wirePart));
            if (ord === null || ord !== index) {
                throw new ReplicaError("malformed_snapshot", "snapshot draft part ordinal does not match its index");
            }
            const active = activePartFromWire(wirePart);
            // Seed the offset baseline from output a running tool already streamed.
            if (wirePart.type === "tool" && active.kind === "tool" && wirePart.state.type === "running" && wirePart.state.output !== undefined) {
                active.tool.output = wirePart.state.output;
                active.tool.outputByteLen = utf8Len(wirePart.state.output);
            }
            parts.push(active);
        }
        return {
            message_id: msg.id,
            run_id: msg.run_id,
            config_rev: msg.config_rev,
            agent: msg.agent,
            created_at_ms: msg.time.created_at_ms,
            parts,
        };
    }
}
//# sourceMappingURL=session.js.map