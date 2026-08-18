package wire
import "libs:json"

import "core:strings"

// Raw content parts.
Input_Content :: struct {
    // @bounded LIMITS.max_input_parts
    // Raw content parts.
    content: []Content_Part,
}

// A named skill invocation with its rendered arguments. Shared by `Input_Skill`
// and `User_Message.skill`.
Skill_Ref :: struct {
    // @bounded 64
    // Skill name.
    name:      string,

    // @unbounded
    // Skill arguments.
    arguments: string,
}

// Write a skill reference.
skill_ref_emit :: proc(e: ^json.Emitter, self: Skill_Ref) {
    json.object_begin(e)
    json.field_string(e, "name", self.name)
    json.field_string(e, "arguments", self.arguments)
    json.object_end(e)
}

// Verify annotated field bounds.
skill_ref_validate :: proc(self: Skill_Ref) -> Validation_Error {
    return enforce_bounded(64, self.name)
}

// Deep-copy into `allocator`.
skill_ref_clone :: proc(self: Skill_Ref, allocator := context.allocator) -> Skill_Ref {
    return Skill_Ref{name = strings.clone(self.name, allocator), arguments = strings.clone(self.arguments, allocator)}
}

// Decode a skill reference straight from the token stream.
skill_ref_from_reader :: proc(d: ^json.Decoder) -> (out: Skill_Ref, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Args,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            out.name = json.dec_string(d) or_return
            seen += {.Name}

        case "arguments":
            out.arguments = json.dec_string(d) or_return
            seen += {.Args}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Args} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Skill invocation.
Input_Skill :: struct {
    using skill: Skill_Ref,
}

// A unit of user input: either raw content or a skill invocation. Non-owning.
Input :: union {
    Input_Content,
    Input_Skill,
}

// Write internally-tagged JSON with `type` first.
input_emit :: proc(e: ^json.Emitter, self: Input) {
    json.object_begin(e)

    switch v in self {
    case Input_Content:
        json.field_string(e, "type", "content")
        json.key(e, "content")
        json.array_begin(e)
        for part in v.content {
            json.elem(e)
            content_part_emit(e, part)
        }

        json.array_end(e)

    case Input_Skill:
        json.field_string(e, "type", "skill")
        json.field_string(e, "name", v.name)
        json.field_string(e, "arguments", v.arguments)
    }

    json.object_end(e)
}

// Verify annotated field bounds.
input_validate :: proc(self: Input) -> Validation_Error {
    switch v in self {
    case Input_Content:
        if len(v.content) > LIMITS.max_input_parts {
            return .Overflow
        }

        for part in v.content {
            content_part_validate(part) or_return
        }

    case Input_Skill:
        return skill_ref_validate(v.skill)
    }

    return .None
}

// Deep-copy into `allocator`.
input_clone :: proc(self: Input, allocator := context.allocator) -> Input {
    switch v in self {
    case Input_Content:
        parts := make([]Content_Part, len(v.content), allocator)
        for i in 0 ..< len(parts) {
            parts[i] = content_part_clone(v.content[i], allocator)
        }

        return Input_Content{content = parts}

    case Input_Skill:
        return Input_Skill{skill = skill_ref_clone(v.skill, allocator)}
    }

    return nil
}

// A queued input waiting behind an active turn.
Queued_Input :: struct {
    // Daemon-minted input id.
    input_id:     Input_Id,

    // @bounded LIMITS.max_input_parts
    // Content parts awaiting execution.
    content:      []Content_Part,

    // Enqueue time, epoch ms.
    queued_at_ms: u64,
}

// Write a Queued_Input object.
queued_input_emit :: proc(e: ^json.Emitter, self: Queued_Input) {
    json.object_begin(e)
    json.field_u64(e, "input_id", u64(self.input_id))
    json.key(e, "content")
    json.array_begin(e)
    for part in self.content {
        json.elem(e)
        content_part_emit(e, part)
    }

    json.array_end(e)
    json.field_u64(e, "queued_at_ms", self.queued_at_ms)
    json.object_end(e)
}

// Verify annotated field bounds.
queued_input_validate :: proc(self: Queued_Input) -> Validation_Error {
    if len(self.content) > LIMITS.max_input_parts {
        return .Overflow
    }

    for part in self.content {
        content_part_validate(part) or_return
    }

    return .None
}

// Deep-copy into `allocator`.
queued_input_clone :: proc(self: Queued_Input, allocator := context.allocator) -> Queued_Input {
    // Iterate the destination length: a failed `make` yields a zero-length slice, so this
    // under-copies gracefully instead of indexing out of bounds under allocation failure.
    parts := make([]Content_Part, len(self.content), allocator)
    for i in 0 ..< len(parts) {
        parts[i] = content_part_clone(self.content[i], allocator)
    }

    return {input_id = self.input_id, content = parts, queued_at_ms = self.queued_at_ms}
}

// Params for `session.send_input`.
Session_Send_Input_Params :: struct {
    // @fixed 16
    // Owning session.
    session_id: Session_Id,

    // Input to enqueue or start.
    input:      Input,
}

// Write session.send_input params.
session_send_input_params_emit :: proc(e: ^json.Emitter, self: Session_Send_Input_Params) {
    json.object_begin(e)
    json.field_id(e, "session_id", ([16]u8)(self.session_id))
    json.key(e, "input")
    input_emit(e, self.input)
    json.object_end(e)
}

// Verify annotated field bounds.
session_send_input_params_validate :: proc(self: Session_Send_Input_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return input_validate(self.input)
}

// Started immediately.
Session_Send_Input_Result_Started :: struct {
    // Daemon-minted input id.
    input_id: Input_Id,

    // Run started to handle this input.
    run_id:   Run_Id,
}

// Queued behind an active turn.
Session_Send_Input_Result_Queued :: struct {
    // Daemon-minted input id.
    input_id: Input_Id,
}

// Result of `session.send_input`: started immediately or queued behind an active turn.
Session_Send_Input_Result :: union {
    Session_Send_Input_Result_Started,
    Session_Send_Input_Result_Queued,
}

// Write internally-tagged JSON with `type` first.
session_send_input_result_emit :: proc(e: ^json.Emitter, self: Session_Send_Input_Result) {
    json.object_begin(e)

    switch v in self {
    case Session_Send_Input_Result_Started:
        json.field_string(e, "type", "started")
        json.field_u64(e, "input_id", u64(v.input_id))
        json.field_u64(e, "run_id", u64(v.run_id))

    case Session_Send_Input_Result_Queued:
        json.field_string(e, "type", "queued")
        json.field_u64(e, "input_id", u64(v.input_id))
    }

    json.object_end(e)
}

// Params for `session.cancel_input`.
Session_Cancel_Input_Params :: struct {
    // @fixed 16
    // Owning session.
    session_id: Session_Id,

    // Input to cancel.
    input_id:   Input_Id,
}

// Write session.cancel_input params.
session_cancel_input_params_emit :: proc(e: ^json.Emitter, self: Session_Cancel_Input_Params) {
    json.object_begin(e)
    json.field_id(e, "session_id", ([16]u8)(self.session_id))
    json.field_u64(e, "input_id", u64(self.input_id))
    json.object_end(e)
}

// Verify annotated field bounds.
session_cancel_input_params_validate :: proc(self: Session_Cancel_Input_Params) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Result of `session.cancel_input`.
Session_Cancel_Input_Result :: struct {
    // Id of the canceled input.
    canceled_input: Input_Id,
}

// Write a session.cancel_input result.
session_cancel_input_result_emit :: proc(e: ^json.Emitter, self: Session_Cancel_Input_Result) {
    json.object_begin(e)
    json.field_u64(e, "canceled_input", u64(self.canceled_input))
    json.object_end(e)
}

// Params for `session.cancel_run`.
Session_Cancel_Run_Params :: struct {
    // @fixed 16
    // Owning session.
    session_id:  Session_Id,

    // @optional
    // Specific run to cancel; omit to cancel the active run.
    run_id:      Maybe(Run_Id),

    // Also drop any queued inputs.
    clear_queue: Maybe(bool),
}

// Write session.cancel_run params, omitting absent optionals.
session_cancel_run_params_emit :: proc(e: ^json.Emitter, self: Session_Cancel_Run_Params) {
    json.object_begin(e)
    json.field_id(e, "session_id", ([16]u8)(self.session_id))

    if id, ok := self.run_id.?; ok {
        json.field_u64(e, "run_id", u64(id))
    }

    if b, ok := self.clear_queue.?; ok {
        json.field_bool(e, "clear_queue", b)
    }

    json.object_end(e)
}

// Verify annotated field bounds.
session_cancel_run_params_validate :: proc(self: Session_Cancel_Run_Params) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Result of `session.cancel_run`.
Session_Cancel_Run_Result :: struct {
    // @required-nullable
    // Run that was canceled; null if none was active.
    canceled_run:       Maybe(Run_Id),

    // @unbounded
    // Queued inputs dropped by `clear_queue`.
    cleared_inputs:     []Input_Id,

    // @required-nullable
    // Compaction run canceled alongside; null if none was active.
    cleared_compaction: Maybe(Run_Id),
}

// Write a session.cancel_run result with explicit nulls for absent runs.
session_cancel_run_result_emit :: proc(e: ^json.Emitter, self: Session_Cancel_Run_Result) {
    json.object_begin(e)
    json.field_required_null_u64(e, "canceled_run", self.canceled_run)

    json.key(e, "cleared_inputs")
    json.array_begin(e)
    for id in self.cleared_inputs {
        json.elem(e)
        json.val_u64(e, u64(id))
    }

    json.array_end(e)

    json.field_required_null_u64(e, "cleared_compaction", self.cleared_compaction)

    json.object_end(e)
}

// Incremental text/reasoning bytes for a draft. `offset` is UTF-8 bytes already
// present: == len appends, < len is a no-op, > len is a gap (call session.resync).
Part_Delta :: struct {
    // @delivery session
    // @fixed 16
    // Owning session.
    session_id: Session_Id,

    // @delivery draft
    // Draft message id.
    message_id: Message_Id,

    // @delivery part
    // Target part ordinal in `content[]`.
    part_id:    Part_Id,

    // @delivery chunk
    // @unbounded
    // UTF-8 bytes to fold at `offset`.
    delta:      string,

    // @delivery offset
    // UTF-8 bytes already applied on the receiver.
    offset:     u64,
}

// Write a Part_Delta object.
part_delta_emit :: proc(e: ^json.Emitter, self: Part_Delta) {
    json.object_begin(e)
    json.field_id(e, "session_id", ([16]u8)(self.session_id))
    json.field_u64(e, "message_id", u64(self.message_id))
    json.field_u64(e, "part_id", u64(self.part_id))
    json.field_string(e, "delta", self.delta)
    json.field_u64(e, "offset", self.offset)
    json.object_end(e)
}

// Verify annotated field bounds.
part_delta_validate :: proc(self: Part_Delta) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Deep-copy into `allocator`.
part_delta_clone :: proc(self: Part_Delta, allocator := context.allocator) -> Part_Delta {
    return Part_Delta {
        session_id = self.session_id,
        message_id = self.message_id,
        part_id = self.part_id,
        delta = strings.clone(self.delta, allocator),
        offset = self.offset,
    }
}

// Decode internally-tagged input straight from the token stream (any member order).
input_from_reader :: proc(d: ^json.Decoder) -> (input: Input, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    tag := json.dec_find_tag(d, "type") or_return

    switch tag {
    case "content":
        content: []Content_Part
        have := false
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "content":
                content = json.dec_array(d, content_part_from_reader) or_return
                have = true

            case "name", "arguments":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Input_Content{content = content}, .None

    case "skill":
        name, arguments: string

        Field :: enum {
            Name,
            Args,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "name":
                name = json.dec_string(d) or_return
                seen += {.Name}

            case "arguments":
                arguments = json.dec_string(d) or_return
                seen += {.Args}

            case "content":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if seen != {.Name, .Args} {
            return nil, .Mismatched_Payload
        }

        return Input_Skill{skill = Skill_Ref{name = name, arguments = arguments}}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a Queued_Input straight from the token stream.
queued_input_from_reader :: proc(d: ^json.Decoder) -> (item: Queued_Input, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Content,
        Queued,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "input_id":
            item.input_id = Input_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Id}

        case "content":
            item.content = json.dec_array(d, content_part_from_reader) or_return
            seen += {.Content}

        case "queued_at_ms":
            item.queued_at_ms = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Queued}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Content, .Queued} {
        return {}, .Mismatched_Payload
    }

    return item, .None
}

// Decode session.send_input params straight from the token stream.
session_send_input_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Session_Send_Input_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Input,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "input":
            params.input = input_from_reader(d) or_return
            seen += {.Input}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Input} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode internally-tagged send-input result straight from the token stream.
session_send_input_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Session_Send_Input_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    tag := json.dec_find_tag(d, "type") or_return

    switch tag {
    case "started":
        input_id, run_id: u64

        Field :: enum {
            Input,
            Run,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "input_id":
                input_id = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
                seen += {.Input}

            case "run_id":
                run_id = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
                seen += {.Run}

            case:
                json.dec_skip(d) or_return
            }
        }

        if seen != {.Input, .Run} {
            return nil, .Mismatched_Payload
        }

        return Session_Send_Input_Result_Started{input_id = Input_Id(input_id), run_id = Run_Id(run_id)}, .None

    case "queued":
        input_id: u64

        Field :: enum {
            Input,
        }

        seen: bit_set[Field]
        for {
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "input_id":
                input_id = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
                seen += {.Input}

            case "run_id":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if .Input not_in seen {
            return nil, .Mismatched_Payload
        }

        return Session_Send_Input_Result_Queued{input_id = Input_Id(input_id)}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode session.cancel_input params straight from the token stream.
session_cancel_input_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Session_Cancel_Input_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Id,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "input_id":
            params.input_id = Input_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Id}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Id} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.cancel_input result straight from the token stream.
session_cancel_input_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Session_Cancel_Input_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "canceled_input":
            result.canceled_input = Input_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode session.cancel_run params straight from the token stream.
session_cancel_run_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Session_Cancel_Run_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Sid,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "run_id":
            params.run_id = Run_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)

        case "clear_queue":
            params.clear_queue = json.dec_bool(d) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    if .Sid not_in seen {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.cancel_run result straight from the token stream.
session_cancel_run_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Session_Cancel_Run_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Run,
        Inputs,
        Compaction,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "canceled_run":
            seen += {.Run}

            if !json.dec_is_null(d) {
                result.canceled_run = Run_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            }

        case "cleared_inputs":
            result.cleared_inputs = json.dec_array(d, _input_id_from_reader) or_return
            seen += {.Inputs}

        case "cleared_compaction":
            seen += {.Compaction}

            if !json.dec_is_null(d) {
                result.cleared_compaction = Run_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            }

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Run, .Inputs, .Compaction} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

@(private)
_input_id_from_reader :: proc(d: ^json.Decoder) -> (out: Input_Id, err: json.Decode_Error) {
    out = Input_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)

    return out, .None
}

// Decode a Part_Delta straight from the token stream.
part_delta_from_reader :: proc(d: ^json.Decoder) -> (pd: Part_Delta, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Pid,
        Delta,
        Offset,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            pd.session_id = Session_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            pd.message_id = Message_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Mid}

        case "part_id":
            pd.part_id = Part_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Pid}

        case "delta":
            pd.delta = json.dec_string(d) or_return
            seen += {.Delta}

        case "offset":
            pd.offset = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Offset}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Pid, .Delta, .Offset} {
        return {}, .Mismatched_Payload
    }

    return pd, .None
}
