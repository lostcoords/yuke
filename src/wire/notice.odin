package wire
import "libs:json"

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
    return json.enum_from_wire(notice_level_wire, s)
}

// Daemon diagnostic notice broadcast to all connections. Non-owning.
Notice :: struct {
    // Severity.
    level:   Notice_Level,

    // @bounded 64
    // Emitting subsystem.
    source:  string,

    // @bounded LIMITS.max_error_message_bytes
    // Human-readable detail.
    message: string,
}

// Decode a notice straight from the token stream.
notice_from_reader :: proc(d: ^json.Decoder) -> (n: Notice, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Level,
        Source,
        Message,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "level":
            n.level = json.dec_enum(d, notice_level_wire) or_return
            seen += {.Level}

        case "source":
            n.source = json.dec_string(d) or_return
            seen += {.Source}

        case "message":
            n.message = json.dec_string(d) or_return
            seen += {.Message}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Level, .Source, .Message} {
        return {}, .Mismatched_Payload
    }

    return n, .None
}

// Write a notice as JSON.
notice_emit :: proc(e: ^json.Emitter, self: Notice) {
    json.object_begin(e)
    json.field_string(e, "level", notice_level_to_wire(self.level))
    json.field_string(e, "source", self.source)
    json.field_string(e, "message", self.message)
    json.object_end(e)
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
