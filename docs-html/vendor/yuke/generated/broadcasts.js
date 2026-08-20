// Generated from schema/wire.json by scripts/generate.ts. Do not edit.
// Server-pushed broadcasts: payload and delivery class per name.
export const DELIVERY_CLASS = {
    "session.summary_changed": "ungated",
    "session.activity_changed": "ungated",
    "session.removed": "ungated",
    "workspace.created": "ungated",
    "workspace.removed": "ungated",
    "permission.rules_changed": "ungated",
    "catalog.changed": "ungated",
    "auth.login_finished": "ungated",
    "auth.changed": "ungated",
    "cron.created": "ungated",
    "cron.updated": "ungated",
    "cron.removed": "ungated",
    "notice": "ungated",
    "message.committed": "durable_gated",
    "run.started": "durable_gated",
    "run.done": "durable_gated",
    "config.changed": "durable_gated",
    "transcript.truncated": "durable_gated",
    "message.started": "live_gated",
    "message.discarded": "live_gated",
    "message.part_added": "live_gated",
    "message.part_delta": "live_droppable",
    "tool.state_changed": "live_gated",
    "tool.output_delta": "live_droppable",
    "input.queued": "live_gated",
    "input.canceled": "live_gated",
    "session.deltas_shed": "live_droppable",
};
export const DELIVERY_RULES = {
    "ungated": { gated: false, droppable: false, sequenced: false },
    "durable_gated": { gated: true, droppable: false, sequenced: true },
    "live_gated": { gated: true, droppable: false, sequenced: false },
    "live_droppable": { gated: true, droppable: true, sequenced: false },
};
/** Member carrying the per-session sequence number, for the broadcasts that have one. */
export const SEQ_FIELD = {
    "message.committed": "seq",
    "run.started": "seq",
    "run.done": "seq",
    "config.changed": "seq",
    "transcript.truncated": "seq",
};
/** Member carrying the owning session id, when a broadcast has one. */
export const SESSION_FIELD = {
    "session.summary_changed": "id",
    "session.activity_changed": "session_id",
    "session.removed": "session_id",
    "message.committed": "session_id",
    "run.started": "session_id",
    "run.done": "session_id",
    "config.changed": "session_id",
    "transcript.truncated": "session_id",
    "message.started": "session_id",
    "message.discarded": "session_id",
    "message.part_added": "session_id",
    "message.part_delta": "session_id",
    "tool.state_changed": "session_id",
    "tool.output_delta": "session_id",
    "input.queued": "session_id",
    "input.canceled": "session_id",
    "session.deltas_shed": "session_id",
};
/** Fields needed to verify continuity for stream-style droppable broadcasts.
 * A droppable broadcast with no draft/part/chunk/offset roles is a shed *marker*
 * (not a stream): the receiver treats the frame itself as proof of loss. */
export const DELTA_FIELDS = {
    "message.part_delta": { draft: "message_id", part: "part_id", chunk: "delta", offset: "offset" },
    "tool.output_delta": { draft: "message_id", part: "part_id", chunk: "delta", offset: "offset" },
};
//# sourceMappingURL=broadcasts.js.map