package wire

import "core:strings"

// Severity of a daemon diagnostic notice.
Notice_Level :: enum {
    // Informational.
    Info,

    // Warning; recoverable.
    Warn,

    // Daemon-side error.
    Error,
}

// Notice_Level <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
notice_level_wire := [Notice_Level]string {
    .Info  = "info",
    .Warn  = "warn",
    .Error = "error",
}

// Wire string for a notice level.
notice_level_to_wire :: proc(l: Notice_Level) -> string {
    return notice_level_wire[l]
}

// Notice level for a wire string; ok is false for an unknown level.
notice_level_from_wire :: proc(s: string) -> (Notice_Level, bool) {
    return enum_from_wire(notice_level_wire, s)
}

// Daemon diagnostic notice broadcast to all connections. Non-owning.
Notice :: struct {
    // Severity.
    level:   Notice_Level,

    // @bounded 64
    // Emitting subsystem.
    source:  string,

    // @bounded 4096
    // Human-readable detail.
    message: string,
}

// Decode a notice straight from the token stream.
notice_from_reader :: proc(d: ^Decoder) -> (n: Notice, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Level,
        Source,
        Message,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "level":
            n.level = dec_enum(d, notice_level_wire) or_return
            seen += {.Level}

        case "source":
            n.source = dec_string(d) or_return
            seen += {.Source}

        case "message":
            n.message = dec_string(d) or_return
            seen += {.Message}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Level, .Source, .Message} {
        return {}, .Mismatched_Payload
    }

    return n, .None
}

// Write a notice as JSON.
notice_emit :: proc(e: ^Emitter, self: Notice) {
    object_begin(e)
    field_string(e, "level", notice_level_to_wire(self.level))
    field_string(e, "source", self.source)
    field_string(e, "message", self.message)
    object_end(e)
}

// Verify annotated field bounds.
notice_validate :: proc(self: Notice) -> Validation_Error {
    enforce_bounded(64, self.source) or_return

    return enforce_bounded(LIMITS.max_error_message_bytes, self.message)
}

// Deep-copy into `allocator`.
notice_clone :: proc(self: Notice, allocator := context.allocator) -> Notice {
    return Notice {
        level = self.level,
        source = strings.clone(self.source, allocator),
        message = strings.clone(self.message, allocator),
    }
}
