package wire
import "libs:json"

// Why a request failed. Distinct from run failures (RunErrorCode).
Error_Code :: enum {
    // Request was syntactically or semantically invalid.
    Bad_Request,

    // Wire-level framing / version violation.
    Bad_Protocol,

    // Unknown RPC method name.
    Unknown_Method,

    // Session id does not exist.
    Unknown_Session,

    // Workspace id does not exist.
    Unknown_Workspace,

    // A paged-query cursor names an invalidated result generation.
    Stale_Cursor,

    // Message id does not exist in this session.
    Unknown_Message,

    // Part index is out of range for the parent message.
    Unknown_Part,

    // Input id does not exist or was already consumed.
    Unknown_Input,

    // `config_rev` is not the session's current revision.
    Unknown_Config_Rev,

    // Job id does not exist.
    Unknown_Job,

    // A run is already active on the target job.
    Job_Busy,

    // Skill name is unknown to this daemon.
    Unknown_Skill,

    // Input was already started and cannot be re-entered.
    Input_Already_Started,

    // Session input queue reached its protocol cap.
    Queue_Full,

    // The run the request targets is not the current run.
    Run_Mismatch,

    // Permission descriptor or prompt id is unknown.
    Permission_Unknown,

    // Permission for this prompt was already decided.
    Permission_Already_Decided,

    // Session is busy and cannot accept the request right now.
    Session_Busy,

    // Session has persistent children and removal did not request a cascade.
    Session_Has_Children,

    // Underlying runtime (model / tool) failed.
    Runtime_Failed,

    // Patch failed structural or content validation.
    Invalid_Patch,

    // Model id is not supported by this daemon.
    Unsupported_Model,

    // Reasoning effort is not supported by the selected model.
    Unsupported_Reasoning,

    // Catch-all for unspecified internal errors.
    Internal,

    // Retry this request after backoff; the connection stays up, only this
    // request was shed. Client behavior: exponential-backoff re-send of the
    // same request.
    Overloaded,
}

// Error_Code -> JSON-RPC `error.code`, indexed by the enum so a missing mapping is
// visible. Numbers are durable: never renumber, append from -31022.
//
// Four carry JSON-RPC's reserved values, which ACP reuses unchanged. Domain codes
// sit at -31000 and down: outside the reserved `-32768..-32000` block, clear of
// LSP's `-32899..-32800`, and clear of ACP's own (see ACP_RESERVED), so a bridge
// passes them through ACP's open "Other" arm rather than renumbering.
@(rodata)
error_code_number := [Error_Code]i32 {
    .Bad_Request                = -32602,
    .Bad_Protocol               = -32600,
    .Unknown_Method             = -32601,
    .Internal                   = -32603,
    .Unknown_Session            = -31000,
    .Unknown_Workspace          = -31001,
    .Stale_Cursor               = -31002,
    .Unknown_Message            = -31003,
    .Unknown_Part               = -31004,
    .Unknown_Input              = -31005,
    .Unknown_Config_Rev         = -31006,
    .Unknown_Job                = -31007,
    .Job_Busy                   = -31008,
    .Unknown_Skill              = -31009,
    .Input_Already_Started      = -31010,
    .Queue_Full                 = -31011,
    .Run_Mismatch               = -31012,
    .Permission_Unknown         = -31013,
    .Permission_Already_Decided = -31014,
    .Session_Busy               = -31015,
    .Session_Has_Children       = -31016,
    .Runtime_Failed             = -31017,
    .Invalid_Patch              = -31018,
    .Unsupported_Model          = -31019,
    .Unsupported_Reasoning      = -31020,
    .Overloaded                 = -31021,
}

// Codes ACP assigns beyond the JSON-RPC reserved set. This protocol defines no
// equivalent — authorization is a front-door concern, cancellation is a method —
// so they stay unclaimed and no code means two things across the two protocols.
@(rodata)
ACP_RESERVED := [?]i32{-32000, -32002, -32800}

// Wire `code` number for an error code.
error_code_to_number :: proc(c: Error_Code) -> i32 {
    return error_code_number[c]
}

// Error code for a wire `code` number; ok is false for an unrecognized number.
error_code_from_number :: proc(n: i32) -> (Error_Code, bool) {
    for c in Error_Code {
        if error_code_number[c] == n {
            return c, true
        }
    }

    return .Internal, false
}

// Error_Code -> diagnostic name. NOT a wire form since `code` became an integer;
// this supplies readable logs and the default `error.message` text.
@(rodata)
error_code_name := [Error_Code]string {
    .Bad_Request                = "bad_request",
    .Bad_Protocol               = "bad_protocol",
    .Unknown_Method             = "unknown_method",
    .Unknown_Session            = "unknown_session",
    .Unknown_Workspace          = "unknown_workspace",
    .Stale_Cursor               = "stale_cursor",
    .Unknown_Message            = "unknown_message",
    .Unknown_Part               = "unknown_part",
    .Unknown_Input              = "unknown_input",
    .Unknown_Config_Rev         = "unknown_config_rev",
    .Unknown_Job                = "unknown_job",
    .Job_Busy                   = "job_busy",
    .Unknown_Skill              = "unknown_skill",
    .Input_Already_Started      = "input_already_started",
    .Queue_Full                 = "queue_full",
    .Run_Mismatch               = "run_mismatch",
    .Permission_Unknown         = "permission_unknown",
    .Permission_Already_Decided = "permission_already_decided",
    .Session_Busy               = "session_busy",
    .Session_Has_Children       = "session_has_children",
    .Runtime_Failed             = "runtime_failed",
    .Invalid_Patch              = "invalid_patch",
    .Unsupported_Model          = "unsupported_model",
    .Unsupported_Reasoning      = "unsupported_reasoning",
    .Internal                   = "internal",
    .Overloaded                 = "overloaded",
}

// Diagnostic name for an error code.
error_code_to_name :: proc(c: Error_Code) -> string {
    return error_code_name[c]
}

// Request failure details. Non-owning.
Error_Object :: struct {
    // Machine-readable error category.
    code:    Error_Code,

    // @bounded LIMITS.max_error_message_bytes
    // Human-readable. Clients branch on `code`, never on this.
    message: string,
}

// Verify the human-readable message bound.
error_object_validate :: proc(self: Error_Object) -> Validation_Error {
    return enforce_bounded(LIMITS.max_error_message_bytes, self.message)
}

// Decode an error object straight from the token stream.
error_object_from_reader :: proc(d: ^Decoder) -> (out: Error_Object, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Code,
        Message,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "code":
            n := dec_i64(d) or_return

            if n < i64(min(i32)) || n > i64(max(i32)) {
                return {}, .Out_Of_Range
            }

            code, known := error_code_from_number(i32(n))

            if !known {
                return {}, .Mismatched_Payload
            }

            out.code = code
            seen += {.Code}

        case "message":
            out.message = dec_string(d) or_return
            seen += {.Message}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Code, .Message} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Write an error object.
error_object_emit :: proc(e: ^json.Emitter, self: Error_Object) {
    json.object_begin(e)
    json.field_i64(e, "code", i64(error_code_to_number(self.code)))
    json.field_string(e, "message", self.message)
    json.object_end(e)
}

// Why a run failed after daemon retry policy was exhausted.
Run_Error_Code :: enum {
    // Provider rejected or failed the request.
    Provider,

    // Provider stream could not be parsed.
    Protocol,

    // Network request failed.
    Network,

    // Provider request timed out.
    Timeout,

    // Provider rate limit was hit.
    Rate_Limited,

    // Plan, quota, or budget exhausted.
    Quota_Exhausted,

    // Provider authentication failed.
    Auth,

    // Model id is unknown.
    Unknown_Model,

    // Reasoning setting is unsupported.
    Unsupported_Reasoning,

    // Tool-call round cap was hit.
    Max_Rounds,

    // Conversation did not fit.
    Context_Overflow,

    // Runtime environment failed.
    Runtime,

    // Unspecified daemon failure.
    Internal,
}

// Run_Error_Code <-> wire string, indexed by the enum.
@(rodata)
run_error_code_wire := [Run_Error_Code]string {
    .Provider              = "provider",
    .Protocol              = "protocol",
    .Network               = "network",
    .Timeout               = "timeout",
    .Rate_Limited          = "rate_limited",
    .Quota_Exhausted       = "quota_exhausted",
    .Auth                  = "auth",
    .Unknown_Model         = "unknown_model",
    .Unsupported_Reasoning = "unsupported_reasoning",
    .Max_Rounds            = "max_rounds",
    .Context_Overflow      = "context_overflow",
    .Runtime               = "runtime",
    .Internal              = "internal",
}

// Wire string for a run error code.
run_error_code_to_wire :: proc(c: Run_Error_Code) -> string {
    return run_error_code_wire[c]
}

// Run error code for a wire string; ok is false for an unknown code.
run_error_code_from_wire :: proc(s: string) -> (Run_Error_Code, bool) {
    return enum_from_wire(run_error_code_wire, s)
}
