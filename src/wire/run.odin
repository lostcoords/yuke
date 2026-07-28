package wire

import "core:strings"

// What kind of run occupies a session.
Run_Kind :: enum {
    // User-driven round of model + tool calls.
    Turn,

    // Background context compaction.
    Compaction,
}

@(rodata)
run_kind_wire := [Run_Kind]string {
    .Turn       = "turn",
    .Compaction = "compaction",
}

// Wire string for a run kind.
run_kind_to_wire :: proc(k: Run_Kind) -> string {
    return run_kind_wire[k]
}

// Run kind for a wire string; ok is false for an unknown kind.
run_kind_from_wire :: proc(s: string) -> (Run_Kind, bool) {
    return enum_from_wire(run_kind_wire, s)
}

// Why a manual compaction did nothing.
Compact_Skip_Reason :: enum {
    // Transcript already fits the context.
    Nothing_To_Summarize,

    // Too few messages to summarize meaningfully.
    Too_Few_Messages,
}

@(rodata)
compact_skip_reason_wire := [Compact_Skip_Reason]string {
    .Nothing_To_Summarize = "nothing_to_summarize",
    .Too_Few_Messages     = "too_few_messages",
}

// Wire string for a compaction skip reason.
compact_skip_reason_to_wire :: proc(r: Compact_Skip_Reason) -> string {
    return compact_skip_reason_wire[r]
}

// Compaction skip reason for a wire string; ok is false for an unknown reason.
compact_skip_reason_from_wire :: proc(s: string) -> (Compact_Skip_Reason, bool) {
    return enum_from_wire(compact_skip_reason_wire, s)
}

// Why a message stopped.
Stop_Reason :: enum {
    // Natural stop.
    Stop,

    // Hit the model's max-output token limit.
    Length,

    // Provider content filter triggered.
    Content_Filter,

    // Stopped to run one or more tool calls.
    Tool_Calls,

    // User or daemon canceled.
    Canceled,

    // Provider or runtime error.
    Error,

    // Stop reason did not map to a known value.
    Unknown,
}

@(rodata)
stop_reason_wire := [Stop_Reason]string {
    .Stop           = "stop",
    .Length         = "length",
    .Content_Filter = "content_filter",
    .Tool_Calls     = "tool_calls",
    .Canceled       = "canceled",
    .Error          = "error",
    .Unknown        = "unknown",
}

// Wire string for a stop reason.
stop_reason_to_wire :: proc(r: Stop_Reason) -> string {
    return stop_reason_wire[r]
}

// Stop reason for a wire string; ok is false for an unknown value.
stop_reason_from_wire :: proc(s: string) -> (Stop_Reason, bool) {
    return enum_from_wire(stop_reason_wire, s)
}

// A time interval for a run that started.
Time_Span :: struct {
    // Start epoch ms.
    started_at_ms: u64,

    // End epoch ms.
    ended_at_ms:   u64,
}

// Decode a time span straight from the token stream.
time_span_from_reader :: proc(d: ^Decoder) -> (span: Time_Span, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Start,
        End,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "started_at_ms":
            span.started_at_ms = dec_u64(d) or_return
            seen += {.Start}

        case "ended_at_ms":
            span.ended_at_ms = dec_u64(d) or_return
            seen += {.End}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Start, .End} {
        return {}, .Mismatched_Payload
    }

    return span, .None
}

// Write a time span.
time_span_emit :: proc(e: ^Emitter, self: Time_Span) {
    object_begin(e)
    field_u64(e, "started_at_ms", self.started_at_ms)
    field_u64(e, "ended_at_ms", self.ended_at_ms)
    object_end(e)
}

// Cancellation timing; an accepted queued run may never start.
Run_Canceled_Timing :: struct {
    // Start epoch ms, or null when canceled before starting.
    started_at_ms: Maybe(u64),

    // Cancellation epoch ms.
    ended_at_ms:   u64,
}

// Decode cancellation timing straight from the token stream.
run_canceled_timing_from_reader :: proc(d: ^Decoder) -> (timing: Run_Canceled_Timing, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Start,
        End,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "started_at_ms":
            seen += {.Start}

            if !dec_is_null(d) {
                timing.started_at_ms = dec_u64(d) or_return
            }

        case "ended_at_ms":
            timing.ended_at_ms = dec_u64(d) or_return
            seen += {.End}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Start, .End} {
        return {}, .Mismatched_Payload
    }

    return timing, .None
}

// Write cancellation timing; `started_at_ms` is always present, null when unset.
run_canceled_timing_emit :: proc(e: ^Emitter, self: Run_Canceled_Timing) {
    object_begin(e)
    field_required_null_u64(e, "started_at_ms", self.started_at_ms)
    field_u64(e, "ended_at_ms", self.ended_at_ms)
    object_end(e)
}

// Token accounting for one assistant message.
Token_Usage :: struct {
    // Input tokens billed.
    input:       u64,

    // Output tokens billed.
    output:      u64,

    // Output tokens used by reasoning.
    reasoning:   u64,

    // Tokens read from prompt cache.
    cache_read:  u64,

    // Tokens written to prompt cache.
    cache_write: u64,
}

// Decode token usage straight from the token stream.
token_usage_from_reader :: proc(d: ^Decoder) -> (usage: Token_Usage, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Input,
        Output,
        Reasoning,
        Read,
        Write,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "input":
            usage.input = dec_u64(d) or_return
            seen += {.Input}

        case "output":
            usage.output = dec_u64(d) or_return
            seen += {.Output}

        case "reasoning":
            usage.reasoning = dec_u64(d) or_return
            seen += {.Reasoning}

        case "cache_read":
            usage.cache_read = dec_u64(d) or_return
            seen += {.Read}

        case "cache_write":
            usage.cache_write = dec_u64(d) or_return
            seen += {.Write}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Input, .Output, .Reasoning, .Read, .Write} {
        return {}, .Mismatched_Payload
    }

    return usage, .None
}

// Write token usage.
token_usage_emit :: proc(e: ^Emitter, self: Token_Usage) {
    object_begin(e)
    field_u64(e, "input", self.input)
    field_u64(e, "output", self.output)
    field_u64(e, "reasoning", self.reasoning)
    field_u64(e, "cache_read", self.cache_read)
    field_u64(e, "cache_write", self.cache_write)
    object_end(e)
}

// A completed turn: it stopped for a stop reason after some round trips.
Run_Outcome_Turn :: struct {
    // Why the turn stopped.
    finish: Stop_Reason,

    // Number of model/tool round trips used.
    rounds: u64,
}

// A manual compaction that produced a summary.
Run_Outcome_Compacted :: struct {
    // New compaction message id.
    message_id: Message_Id,
}

// A manual compaction that did nothing.
Run_Outcome_Skipped :: struct {
    // Why nothing was compacted.
    reason: Compact_Skip_Reason,
}

// A run canceled by the user or daemon. Its timing rides the terminal envelope.
Run_Outcome_Canceled :: struct {}

// A run that failed after daemon retry policy was exhausted.
Run_Outcome_Failed :: struct {
    // Failure category.
    code:    Run_Error_Code,

    // @bounded 4096
    // Human-readable failure.
    message: string,
}

// A run's terminal outcome, discriminated by `type`. Cancellation and failure are
// terminal outcomes here (folded in from the former run.canceled / run.failed).
Run_Outcome :: union {
    Run_Outcome_Turn,
    Run_Outcome_Compacted,
    Run_Outcome_Skipped,
    Run_Outcome_Canceled,
    Run_Outcome_Failed,
}

// Decode the terminal outcome straight from the token stream (any member order).
run_outcome_from_reader :: proc(d: ^Decoder) -> (outcome: Run_Outcome, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "turn":
        finish: Stop_Reason
        rounds: u64

        Field :: enum {
            Finish,
            Rounds,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "finish":
                finish = dec_enum(d, stop_reason_wire) or_return
                seen += {.Finish}

            case "rounds":
                rounds = dec_u64(d) or_return
                seen += {.Rounds}

            case "message_id", "reason", "code", "message":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Finish, .Rounds} {
            return nil, .Mismatched_Payload
        }

        return Run_Outcome_Turn{finish = finish, rounds = rounds}, .None

    case "compacted":
        message_id: u64
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "message_id":
                message_id = dec_u64(d) or_return
                have = true

            case "finish", "rounds", "reason", "code", "message":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Run_Outcome_Compacted{message_id = Message_Id(message_id)}, .None

    case "skipped":
        reason: Compact_Skip_Reason
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "reason":
                reason = dec_enum(d, compact_skip_reason_wire) or_return
                have = true

            case "finish", "rounds", "message_id", "code", "message":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Run_Outcome_Skipped{reason = reason}, .None

    case "canceled":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "finish", "rounds", "message_id", "reason", "code", "message":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Run_Outcome_Canceled{}, .None

    case "failed":
        code: Run_Error_Code
        message: string

        Field :: enum {
            Code,
            Message,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "code":
                code = dec_enum(d, run_error_code_wire) or_return
                seen += {.Code}

            case "message":
                message = dec_string(d) or_return
                seen += {.Message}

            case "finish", "rounds", "message_id", "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Code, .Message} {
            return nil, .Mismatched_Payload
        }

        return Run_Outcome_Failed{code = code, message = message}, .None
    }

    return nil, .Mismatched_Payload
}

// Write internally-tagged JSON with `type` first.
run_outcome_emit :: proc(e: ^Emitter, self: Run_Outcome) {
    object_begin(e)

    switch v in self {
    case Run_Outcome_Turn:
        field_string(e, "type", "turn")
        field_string(e, "finish", stop_reason_to_wire(v.finish))
        field_u64(e, "rounds", v.rounds)

    case Run_Outcome_Compacted:
        field_string(e, "type", "compacted")
        field_u64(e, "message_id", u64(v.message_id))

    case Run_Outcome_Skipped:
        field_string(e, "type", "skipped")
        field_string(e, "reason", compact_skip_reason_to_wire(v.reason))

    case Run_Outcome_Canceled:
        field_string(e, "type", "canceled")

    case Run_Outcome_Failed:
        field_string(e, "type", "failed")
        field_string(e, "code", run_error_code_to_wire(v.code))
        field_string(e, "message", v.message)
    }

    object_end(e)
}

// Verify annotated field bounds.
run_outcome_validate :: proc(self: Run_Outcome) -> Validation_Error {
    #partial switch v in self {
    case Run_Outcome_Failed:
        return enforce_bounded(LIMITS.max_error_message_bytes, v.message)
    }

    return .None
}

// Deep-copy into `allocator`.
run_outcome_clone :: proc(self: Run_Outcome, allocator := context.allocator) -> Run_Outcome {
    #partial switch v in self {
    case Run_Outcome_Failed:
        return Run_Outcome_Failed{code = v.code, message = strings.clone(v.message, allocator)}
    }

    return self
}
