// Generated from schema/wire.json by scripts/generate.ts. Do not edit.
// Request-failure codes and their durable JSON-RPC numbers.
export const ERROR_CODES = {
    /** Request was syntactically or semantically invalid. */
    BadRequest: -32602,
    /** Wire-level framing / version violation. */
    BadProtocol: -32600,
    /** Unknown RPC method name. */
    UnknownMethod: -32601,
    /** Session id does not exist. */
    UnknownSession: -31000,
    /** Workspace id does not exist. */
    UnknownWorkspace: -31001,
    /** A paged-query cursor names an invalidated result generation. */
    StaleCursor: -31002,
    /** Message id does not exist in this session. */
    UnknownMessage: -31003,
    /** Part index is out of range for the parent message. */
    UnknownPart: -31004,
    /** Input id does not exist or was already consumed. */
    UnknownInput: -31005,
    /** `config_rev` is not the session's current revision. */
    UnknownConfigRev: -31006,
    /** Job id does not exist. */
    UnknownJob: -31007,
    /** A run is already active on the target job. */
    JobBusy: -31008,
    /** Skill name is unknown to this daemon. */
    UnknownSkill: -31009,
    /** Input was already started and cannot be re-entered. */
    InputAlreadyStarted: -31010,
    /** Session input queue reached its protocol cap. */
    QueueFull: -31011,
    /** The run the request targets is not the current run. */
    RunMismatch: -31012,
    /** Permission descriptor or prompt id is unknown. */
    PermissionUnknown: -31013,
    /** Permission for this prompt was already decided. */
    PermissionAlreadyDecided: -31014,
    /** Session is busy and cannot accept the request right now. */
    SessionBusy: -31015,
    /** Session has persistent children and removal did not request a cascade. */
    SessionHasChildren: -31016,
    /** Underlying runtime (model / tool) failed. */
    RuntimeFailed: -31017,
    /** Patch failed structural or content validation. */
    InvalidPatch: -31018,
    /** Model id is not supported by this daemon. */
    UnsupportedModel: -31019,
    /** Reasoning effort is not supported by the selected model. */
    UnsupportedReasoning: -31020,
    /** Catch-all for unspecified internal errors. */
    Internal: -32603,
    /** Retry this request after backoff; the connection stays up, only this request was shed. Client behavior: exponential-backoff re-send of the same request. */
    Overloaded: -31021,
};
//# sourceMappingURL=errors.js.map