package wire

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
}

// Error_Code <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
error_code_wire := [Error_Code]string {
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
}

// Wire string for an error code.
error_code_to_wire :: proc(c: Error_Code) -> string {
    return error_code_wire[c]
}

// Error code for a wire string; ok is false for an unknown code.
error_code_from_wire :: proc(s: string) -> (Error_Code, bool) {
    return enum_from_wire(error_code_wire, s)
}

// Request failure details. Non-owning.
Error_Object :: struct {
    // Machine-readable error category.
    code:    Error_Code,

    // Human-readable. Clients branch on `code`, never on this. @bounded 4096
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
            out.code = dec_enum(d, error_code_wire) or_return
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
error_object_emit :: proc(e: ^Emitter, self: Error_Object) {
    object_begin(e)
    field_string(e, "code", error_code_to_wire(self.code))
    field_string(e, "message", self.message)
    object_end(e)
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
