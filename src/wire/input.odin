package wire

import "core:strings"

// Raw content parts. At most LIMITS.max_input_parts.
Input_Content :: struct {
    // Raw content parts. At most LIMITS.max_input_parts.
    content: []Content_Part,
}

// Skill invocation.
Input_Skill :: struct {
    // Skill name. @bounded 64
    name:      string,

    // Skill arguments. @unbounded
    arguments: string,
}

// A unit of user input: either raw content or a skill invocation. Non-owning.
Input :: union {
    Input_Content,
    Input_Skill,
}

// Write internally-tagged JSON with `type` first.
input_emit :: proc(e: ^Emitter, self: Input) {
    object_begin(e)

    switch v in self {
    case Input_Content:
        field_string(e, "type", "content")
        key(e, "content")
        array_begin(e)
        for part in v.content {
            elem(e)
            content_part_emit(e, part)
        }

        array_end(e)

    case Input_Skill:
        field_string(e, "type", "skill")
        field_string(e, "name", v.name)
        field_string(e, "arguments", v.arguments)
    }

    object_end(e)
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
        return enforce_bounded(64, v.name)
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
        return Input_Skill{name = strings.clone(v.name, allocator), arguments = strings.clone(v.arguments, allocator)}
    }

    return nil
}

// A queued input waiting behind an active turn.
Queued_Input :: struct {
    // Daemon-minted input id.
    input_id:     Input_Id,

    // Content parts awaiting execution. At most LIMITS.max_input_parts.
    content:      []Content_Part,

    // Enqueue time, epoch ms.
    queued_at_ms: u64,
}

// Write a Queued_Input object.
queued_input_emit :: proc(e: ^Emitter, self: Queued_Input) {
    object_begin(e)
    field_u64(e, "input_id", u64(self.input_id))
    key(e, "content")
    array_begin(e)
    for part in self.content {
        elem(e)
        content_part_emit(e, part)
    }

    array_end(e)
    field_u64(e, "queued_at_ms", self.queued_at_ms)
    object_end(e)
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

    return Queued_Input{input_id = self.input_id, content = parts, queued_at_ms = self.queued_at_ms}
}

// Params for `session.send_input`.
Send_Input_Params :: struct {
    // Owning session. @fixed 16
    session_id: Session_Id,

    // Input to enqueue or start.
    input:      Input,
}

// Write session.send_input params.
send_input_params_emit :: proc(e: ^Emitter, self: Send_Input_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    key(e, "input")
    input_emit(e, self.input)
    object_end(e)
}

// Verify annotated field bounds.
send_input_params_validate :: proc(self: Send_Input_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return input_validate(self.input)
}

// Started immediately.
Send_Input_Result_Started :: struct {
    // Daemon-minted input id.
    input_id: Input_Id,

    // Run started to handle this input.
    run_id:   Run_Id,
}

// Queued behind an active turn.
Send_Input_Result_Queued :: struct {
    // Daemon-minted input id.
    input_id: Input_Id,
}

// Result of `session.send_input`: started immediately or queued behind an active turn.
Send_Input_Result :: union {
    Send_Input_Result_Started,
    Send_Input_Result_Queued,
}

// Write internally-tagged JSON with `type` first.
send_input_result_emit :: proc(e: ^Emitter, self: Send_Input_Result) {
    object_begin(e)

    switch v in self {
    case Send_Input_Result_Started:
        field_string(e, "type", "started")
        field_u64(e, "input_id", u64(v.input_id))
        field_u64(e, "run_id", u64(v.run_id))

    case Send_Input_Result_Queued:
        field_string(e, "type", "queued")
        field_u64(e, "input_id", u64(v.input_id))
    }

    object_end(e)
}

// Params for `session.cancel_input`.
Cancel_Input_Params :: struct {
    // Owning session. @fixed 16
    session_id: Session_Id,

    // Input to cancel.
    input_id:   Input_Id,
}

// Write session.cancel_input params.
cancel_input_params_emit :: proc(e: ^Emitter, self: Cancel_Input_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "input_id", u64(self.input_id))
    object_end(e)
}

// Verify annotated field bounds.
cancel_input_params_validate :: proc(self: Cancel_Input_Params) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Result of `session.cancel_input`.
Cancel_Input_Result :: struct {
    // Id of the canceled input.
    canceled_input: Input_Id,
}

// Write a session.cancel_input result.
cancel_input_result_emit :: proc(e: ^Emitter, self: Cancel_Input_Result) {
    object_begin(e)
    field_u64(e, "canceled_input", u64(self.canceled_input))
    object_end(e)
}

// Params for `session.cancel_run`.
Cancel_Run_Params :: struct {
    // Owning session. @fixed 16
    session_id:  Session_Id,

    // Specific run to cancel; null cancels the active run.
    run_id:      Maybe(Run_Id),

    // Also drop any queued inputs.
    clear_queue: Maybe(bool),
}

// Write session.cancel_run params, omitting absent optionals.
cancel_run_params_emit :: proc(e: ^Emitter, self: Cancel_Run_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))

    if id, ok := self.run_id.?; ok {
        field_u64(e, "run_id", u64(id))
    }

    if b, ok := self.clear_queue.?; ok {
        field_bool(e, "clear_queue", b)
    }

    object_end(e)
}

// Verify annotated field bounds.
cancel_run_params_validate :: proc(self: Cancel_Run_Params) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Result of `session.cancel_run`.
Cancel_Run_Result :: struct {
    // Run that was canceled; null if none was active.
    canceled_run:       Maybe(Run_Id),

    // Queued inputs dropped by `clear_queue`.
    cleared_inputs:     []Input_Id,

    // Compaction run canceled alongside, if any.
    cleared_compaction: Maybe(Run_Id),
}

// Write a session.cancel_run result, omitting absent optionals.
cancel_run_result_emit :: proc(e: ^Emitter, self: Cancel_Run_Result) {
    object_begin(e)

    if id, ok := self.canceled_run.?; ok {
        field_u64(e, "canceled_run", u64(id))
    }

    key(e, "cleared_inputs")
    array_begin(e)
    for id in self.cleared_inputs {
        elem(e)
        val_u64(e, u64(id))
    }

    array_end(e)

    if id, ok := self.cleared_compaction.?; ok {
        field_u64(e, "cleared_compaction", u64(id))
    }

    object_end(e)
}

// Incremental text/reasoning bytes for a draft. `offset` is UTF-8 bytes already
// present: == len appends, < len is a no-op, > len is a gap (call session.resync).
Part_Delta :: struct {
    // Owning session. @fixed 16
    session_id: Session_Id,

    // Draft message id.
    message_id: Message_Id,

    // Target part ordinal in `content[]`.
    part_id:    Part_Id,

    // UTF-8 bytes to fold at `offset`.
    delta:      string,

    // UTF-8 bytes already applied on the receiver.
    offset:     u64,
}

// Write a Part_Delta object.
part_delta_emit :: proc(e: ^Emitter, self: Part_Delta) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "message_id", u64(self.message_id))
    field_u64(e, "part_id", u64(self.part_id))
    field_string(e, "delta", self.delta)
    field_u64(e, "offset", self.offset)
    object_end(e)
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

// --- streaming decoders ---

// Decode internally-tagged input straight from the token stream (any member order).
input_from_reader :: proc(d: ^Decoder) -> (input: Input, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "content":
        content: []Content_Part
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "content":
                content = dec_array(d, content_part_from_reader) or_return
                have = true

            case "name", "arguments":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
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
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "name":
                name = dec_string(d) or_return
                seen += {.Name}

            case "arguments":
                arguments = dec_string(d) or_return
                seen += {.Args}

            case "content":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Name, .Args} {
            return nil, .Mismatched_Payload
        }

        return Input_Skill{name = name, arguments = arguments}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a Queued_Input straight from the token stream.
queued_input_from_reader :: proc(d: ^Decoder) -> (item: Queued_Input, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Content,
        Queued,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "input_id":
            item.input_id = Input_Id(dec_u64(d) or_return)
            seen += {.Id}

        case "content":
            item.content = dec_array(d, content_part_from_reader) or_return
            seen += {.Content}

        case "queued_at_ms":
            item.queued_at_ms = dec_u64(d) or_return
            seen += {.Queued}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Content, .Queued} {
        return {}, .Mismatched_Payload
    }

    return item, .None
}

// Decode session.send_input params straight from the token stream.
send_input_params_from_reader :: proc(d: ^Decoder) -> (params: Send_Input_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Input,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "input":
            params.input = input_from_reader(d) or_return
            seen += {.Input}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Input} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode internally-tagged send-input result straight from the token stream.
send_input_result_from_reader :: proc(d: ^Decoder) -> (result: Send_Input_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "started":
        input_id, run_id: u64

        Field :: enum {
            Input,
            Run,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "input_id":
                input_id = dec_u64(d) or_return
                seen += {.Input}

            case "run_id":
                run_id = dec_u64(d) or_return
                seen += {.Run}

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Input, .Run} {
            return nil, .Mismatched_Payload
        }

        return Send_Input_Result_Started{input_id = Input_Id(input_id), run_id = Run_Id(run_id)}, .None

    case "queued":
        input_id: u64

        Field :: enum {
            Input,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "input_id":
                input_id = dec_u64(d) or_return
                seen += {.Input}

            case "run_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Input not_in seen {
            return nil, .Mismatched_Payload
        }

        return Send_Input_Result_Queued{input_id = Input_Id(input_id)}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode session.cancel_input params straight from the token stream.
cancel_input_params_from_reader :: proc(d: ^Decoder) -> (params: Cancel_Input_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Id,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "input_id":
            params.input_id = Input_Id(dec_u64(d) or_return)
            seen += {.Id}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Id} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.cancel_input result straight from the token stream.
cancel_input_result_from_reader :: proc(d: ^Decoder) -> (result: Cancel_Input_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "canceled_input":
            result.canceled_input = Input_Id(dec_u64(d) or_return)
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode session.cancel_run params straight from the token stream.
cancel_run_params_from_reader :: proc(d: ^Decoder) -> (params: Cancel_Run_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "run_id":
            params.run_id = Run_Id(dec_u64(d) or_return)

        case "clear_queue":
            params.clear_queue = dec_bool(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if .Sid not_in seen {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.cancel_run result straight from the token stream.
cancel_run_result_from_reader :: proc(d: ^Decoder) -> (result: Cancel_Run_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Inputs,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "canceled_run":
            result.canceled_run = Run_Id(dec_u64(d) or_return)

        case "cleared_inputs":
            result.cleared_inputs = dec_array(d, _input_id_from_reader) or_return
            seen += {.Inputs}

        case "cleared_compaction":
            result.cleared_compaction = Run_Id(dec_u64(d) or_return)

        case:
            dec_skip(d) or_return
        }
    }

    if .Inputs not_in seen {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

@(private)
_input_id_from_reader :: proc(d: ^Decoder) -> (out: Input_Id, err: Validation_Error) {
    out = Input_Id(dec_u64(d) or_return)

    return out, .None
}

// Decode a Part_Delta straight from the token stream.
part_delta_from_reader :: proc(d: ^Decoder) -> (pd: Part_Delta, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Pid,
        Delta,
        Offset,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            pd.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            pd.message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Mid}

        case "part_id":
            pd.part_id = Part_Id(dec_u64(d) or_return)
            seen += {.Pid}

        case "delta":
            pd.delta = dec_string(d) or_return
            seen += {.Delta}

        case "offset":
            pd.offset = dec_u64(d) or_return
            seen += {.Offset}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Pid, .Delta, .Offset} {
        return {}, .Mismatched_Payload
    }

    return pd, .None
}
