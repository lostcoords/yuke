package wire

import "core:strings"

// Creation/completion timestamps on an assistant message.
Message_Time :: struct {
    // Creation epoch ms.
    created_at_ms:   u64,

    // @required-nullable
    // Completion epoch ms; null while still in flight.
    completed_at_ms: Maybe(u64),
}

// Write creation/completion timestamps with an explicit null while still in flight.
message_time_emit :: proc(e: ^Emitter, self: Message_Time) {
    object_begin(e)
    field_u64(e, "created_at_ms", self.created_at_ms)
    field_required_null_u64(e, "completed_at_ms", self.completed_at_ms)
    object_end(e)
}

// Creation timestamp on a user or compaction message. These message kinds carry
// `{ created_at_ms }` only — no `completed_at_ms` (that is assistant-only).
Created_Time :: struct {
    // Creation epoch ms.
    created_at_ms: u64,
}

// Write a creation timestamp.
created_time_emit :: proc(e: ^Emitter, self: Created_Time) {
    object_begin(e)
    field_u64(e, "created_at_ms", self.created_at_ms)
    object_end(e)
}

// Structured error on an assistant message with `finish: "error"`. Non-owning.
Message_Error :: struct {
    // @bounded 128
    // Provider error category string.
    type:    string,

    // @bounded LIMITS.max_error_message_bytes
    // Human-readable error.
    message: string,
}

// Write a structured message error.
message_error_emit :: proc(e: ^Emitter, self: Message_Error) {
    object_begin(e)
    field_string(e, "type", self.type)
    field_string(e, "message", self.message)
    object_end(e)
}

// Verify annotated field bounds.
message_error_validate :: proc(self: Message_Error) -> Validation_Error {
    enforce_bounded(128, self.type) or_return

    return enforce_bounded(LIMITS.max_error_message_bytes, self.message)
}

// Deep-copy into `allocator`.
message_error_clone :: proc(self: Message_Error, allocator := context.allocator) -> Message_Error {
    return {type = strings.clone(self.type, allocator), message = strings.clone(self.message, allocator)}
}

// ---------------------------------------------------------------------------
// AssistantPart: text | reasoning | tool
// ---------------------------------------------------------------------------

// Text assistant part payload. Non-owning.
Text_Part :: struct {
    // Part ordinal in the message content array.
    id:   Part_Id,

    // @unbounded
    // UTF-8 text.
    text: string,
}

// Reasoning assistant part payload. Non-owning.
Reasoning_Part :: struct {
    // Part ordinal in the message content array.
    id:        Part_Id,

    // @unbounded
    // UTF-8 reasoning trace.
    text:      string,

    // @unbounded
    // Opaque provider data: Anthropic's extended-thinking block signature,
    // delivered by `signature_delta`. Empty when the provider issued none.
    // Persisted verbatim and replayed verbatim on the next request of a
    // tool-use conversation; never interpreted. A part carrying one must never
    // be collapsed or reordered by a normalization pass, even when `text` is
    // empty: the signature covers the block at its position.
    signature: string,
}

// Tool assistant part payload. Non-owning.
Tool_Part :: struct {
    // Part ordinal in the message content array.
    id:               Part_Id,

    // @unbounded
    // Provider identity; never used to address the part.
    call_id:          Maybe(string),

    // @bounded 128
    // Tool name.
    name:             string,

    // @unbounded
    // Opaque JSON-encoded arguments.
    arguments:        string,

    // @bounded LIMITS.max_views_per_tool
    // Display-only input views.
    input_view:       Maybe([]View),

    // Current tool state.
    state:            Tool_State,

    // Local permission lifecycle. Absent under `pending`; options-and-no-decision
    // under `waiting_permission`; decided when present, except under `canceled`.
    permission_state: Maybe(Permission_State),
}

// Verify annotated field bounds and the permission/state cross-field invariant.
tool_part_validate :: proc(self: Tool_Part) -> Validation_Error {
    enforce_bounded(128, self.name) or_return

    if views, ok := self.input_view.?; ok {
        view_validate_slice(views) or_return
    }

    tool_state_validate(self.state) or_return

    return tool_permission_state_validate(self.state, self.permission_state)
}

// Enforce which permission shapes each tool state admits. Shared by the tool part and
// the `tool.state_changed` payload, which carry the same pair.
tool_permission_state_validate :: proc(
    state: Tool_State,
    permission_state: Maybe(Permission_State),
) -> Validation_Error {
    p, has_perm := permission_state.?

    if has_perm {
        permission_state_validate(p) or_return
    }

    _, has_dec := p.decision.?
    _, has_opts := p.options.?

    switch _ in state {
    case Tool_State_Pending:
        if has_perm {
            return .Mismatched_Payload
        }

    case Tool_State_Waiting_Permission:
        if !has_perm || !has_opts || has_dec {
            return .Mismatched_Payload
        }

    case Tool_State_Running, Tool_State_Completed, Tool_State_Error, Tool_State_Denied:
        if has_perm && !has_dec {
            return .Mismatched_Payload
        }

    // Canceled while awaiting a decision leaves the permission state undecided.
    case Tool_State_Canceled:
    }

    return .None
}

// Deep-copy into `allocator`.
tool_part_clone :: proc(self: Tool_Part, allocator := context.allocator) -> Tool_Part {
    call_id: Maybe(string)

    if c, ok := self.call_id.?; ok {
        call_id = strings.clone(c, allocator)
    }

    input_view: Maybe([]View)

    if views, ok := self.input_view.?; ok {
        input_view = view_clone_slice(views, allocator)
    }

    permission_state: Maybe(Permission_State)

    if p, ok := self.permission_state.?; ok {
        permission_state = permission_state_clone(p, allocator)
    }

    return Tool_Part {
        id = self.id,
        call_id = call_id,
        name = strings.clone(self.name, allocator),
        arguments = strings.clone(self.arguments, allocator),
        input_view = input_view,
        state = tool_state_clone(self.state, allocator),
        permission_state = permission_state,
    }
}

// One element of an assistant message `content[]`. Non-owning.
Assistant_Part :: union {
    // Assistant text output.
    Text_Part,

    // Model reasoning trace.
    Reasoning_Part,

    // A tool call and its state.
    Tool_Part,
}

// Write internally-tagged JSON with `type` first.
assistant_part_emit :: proc(e: ^Emitter, self: Assistant_Part) {
    object_begin(e)

    switch v in self {
    case Text_Part:
        field_string(e, "type", "text")
        field_u64(e, "id", u64(v.id))
        field_string(e, "text", v.text)

    case Reasoning_Part:
        field_string(e, "type", "reasoning")
        field_u64(e, "id", u64(v.id))
        field_string(e, "text", v.text)

        if v.signature != "" {
            field_string(e, "signature", v.signature)
        }

    case Tool_Part:
        field_string(e, "type", "tool")
        field_u64(e, "id", u64(v.id))
        field_string_opt(e, "call_id", v.call_id)
        field_string(e, "name", v.name)
        field_string(e, "arguments", v.arguments)

        if views, ok := v.input_view.?; ok {
            _emit_view_slice(e, "input_view", views)
        }

        key(e, "state")
        tool_state_emit(e, v.state)

        if p, ok := v.permission_state.?; ok {
            key(e, "permission")
            _permission_state_emit(e, p)
        }
    }

    object_end(e)
}

// Verify annotated field bounds.
assistant_part_validate :: proc(self: Assistant_Part) -> Validation_Error {
    #partial switch v in self {
    case Tool_Part:
        return tool_part_validate(v)
    }

    return .None
}

// Deep-copy into `allocator`.
assistant_part_clone :: proc(self: Assistant_Part, allocator := context.allocator) -> Assistant_Part {
    switch v in self {
    case Text_Part:
        return Text_Part{id = v.id, text = strings.clone(v.text, allocator)}

    case Reasoning_Part:
        return Reasoning_Part {
            id = v.id,
            text = strings.clone(v.text, allocator),
            signature = strings.clone(v.signature, allocator),
        }

    case Tool_Part:
        return tool_part_clone(v, allocator)
    }

    return nil
}

// Part ordinal, whichever variant.
assistant_part_id :: proc(self: Assistant_Part) -> Part_Id {
    switch v in self {
    case Text_Part:
        return v.id

    case Reasoning_Part:
        return v.id

    case Tool_Part:
        return v.id
    }

    return 0
}

// ---------------------------------------------------------------------------
// ToolState: pending | waiting_permission | running | completed | error | denied | canceled
// ---------------------------------------------------------------------------

// Not yet started.
Tool_State_Pending :: struct {}

// Awaiting a permission decision.
Tool_State_Waiting_Permission :: struct {}

// Call is executing.
Tool_State_Running :: struct {
    // Run start epoch ms.
    started_at_ms: u64,

    // @bounded LIMITS.max_tool_output_stream_bytes
    // Accumulated display output streamed so far. Present in a resync
    // snapshot of a running tool, absent in the live transition into
    // `running`. Its UTF-8 byte length is the next `tool.output_delta`
    // offset baseline.
    output:        Maybe(string),
}

// Call finished successfully.
Tool_State_Completed :: struct {
    // @unbounded
    // Model-facing output text.
    output:      string,

    // @bounded LIMITS.max_views_per_tool
    // Display-only rendering hints.
    view:        Maybe([]View),

    // Wall-clock duration in ms.
    duration_ms: u64,
}

// Call failed.
Tool_State_Error :: struct {
    // @unbounded
    // Model-facing error text.
    message:     string,

    // @bounded LIMITS.max_views_per_tool
    // Display-only rendering hints.
    view:        Maybe([]View),

    // Wall-clock duration in ms.
    duration_ms: u64,
}

// Permission was denied.
Tool_State_Denied :: struct {
    // @unbounded
    // Model-facing reason.
    reason:    string,

    // Who denied.
    denied_by: Denied_By,
}

// Call was canceled.
Tool_State_Canceled :: struct {
    // @required-nullable
    // Null when the call never started running.
    duration_ms: Maybe(u64),
}

// Lifecycle state of a tool part. Non-owning.
Tool_State :: union {
    Tool_State_Pending,
    Tool_State_Waiting_Permission,
    Tool_State_Running,
    Tool_State_Completed,
    Tool_State_Error,
    Tool_State_Denied,
    Tool_State_Canceled,
}

// Write internally-tagged JSON with `type` first.
tool_state_emit :: proc(e: ^Emitter, self: Tool_State) {
    object_begin(e)

    switch v in self {
    case Tool_State_Pending:
        field_string(e, "type", "pending")

    case Tool_State_Waiting_Permission:
        field_string(e, "type", "waiting_permission")

    case Tool_State_Running:
        field_string(e, "type", "running")
        field_u64(e, "started_at_ms", v.started_at_ms)
        field_string_opt(e, "output", v.output)

    case Tool_State_Completed:
        field_string(e, "type", "completed")
        field_string(e, "output", v.output)

        if views, ok := v.view.?; ok {
            _emit_view_slice(e, "view", views)
        }

        field_u64(e, "duration_ms", v.duration_ms)

    case Tool_State_Error:
        field_string(e, "type", "error")
        field_string(e, "error", v.message)

        if views, ok := v.view.?; ok {
            _emit_view_slice(e, "view", views)
        }

        field_u64(e, "duration_ms", v.duration_ms)

    case Tool_State_Denied:
        field_string(e, "type", "denied")
        field_string(e, "reason", v.reason)
        field_string(e, "denied_by", denied_by_to_wire(v.denied_by))

    case Tool_State_Canceled:
        field_string(e, "type", "canceled")
        field_required_null_u64(e, "duration_ms", v.duration_ms)
    }

    object_end(e)
}

// Verify annotated field bounds.
tool_state_validate :: proc(self: Tool_State) -> Validation_Error {
    switch v in self {
    case Tool_State_Pending, Tool_State_Waiting_Permission, Tool_State_Denied, Tool_State_Canceled:
    case Tool_State_Running:
        if out, ok := v.output.?; ok {
            enforce_bounded(LIMITS.max_tool_output_stream_bytes, out) or_return
        }

    case Tool_State_Completed:
        if views, ok := v.view.?; ok {
            view_validate_slice(views) or_return
        }

    case Tool_State_Error:
        if views, ok := v.view.?; ok {
            view_validate_slice(views) or_return
        }
    }

    return .None
}

// Deep-copy into `allocator`.
tool_state_clone :: proc(self: Tool_State, allocator := context.allocator) -> Tool_State {
    switch v in self {
    case Tool_State_Pending:
        return Tool_State_Pending{}

    case Tool_State_Waiting_Permission:
        return Tool_State_Waiting_Permission{}

    case Tool_State_Running:
        output: Maybe(string)

        if out, ok := v.output.?; ok {
            output = strings.clone(out, allocator)
        }

        return Tool_State_Running{started_at_ms = v.started_at_ms, output = output}

    case Tool_State_Completed:
        view: Maybe([]View)

        if views, ok := v.view.?; ok {
            view = view_clone_slice(views, allocator)
        }

        return Tool_State_Completed {
            output = strings.clone(v.output, allocator),
            view = view,
            duration_ms = v.duration_ms,
        }

    case Tool_State_Error:
        view: Maybe([]View)

        if views, ok := v.view.?; ok {
            view = view_clone_slice(views, allocator)
        }

        return Tool_State_Error {
            message = strings.clone(v.message, allocator),
            view = view,
            duration_ms = v.duration_ms,
        }

    case Tool_State_Denied:
        return Tool_State_Denied{reason = strings.clone(v.reason, allocator), denied_by = v.denied_by}

    case Tool_State_Canceled:
        return Tool_State_Canceled{duration_ms = v.duration_ms}
    }

    return nil
}

// NOTE: Compaction_Reason and its wire table live in session.odin (source of
// truth); Compaction_Message references them directly from this same package.

// ---------------------------------------------------------------------------
// Message: user | assistant | compaction
// ---------------------------------------------------------------------------

// User transcript message payload. Non-owning.
User_Message :: struct {
    // Message id.
    id:       Message_Id,

    // @bounded LIMITS.max_input_parts
    // Content parts in rendered order.
    content:  []Content_Part,

    // The accepted input this message came from (client- or daemon-minted).
    input_id: Input_Id,

    // Skill this message's rendered body came from, if any.
    skill:    Maybe(Skill_Ref),

    // Creation timestamp.
    time:     Created_Time,
}

// Deep-copy into `allocator`.
user_message_clone :: proc(self: User_Message, allocator := context.allocator) -> User_Message {
    // Iterate the destination length: a failed `make` yields a zero-length slice, so this
    // under-copies gracefully instead of indexing out of bounds under allocation failure.
    parts := make([]Content_Part, len(self.content), allocator)
    for i in 0 ..< len(parts) {
        parts[i] = content_part_clone(self.content[i], allocator)
    }

    out := User_Message {
        id       = self.id,
        content  = parts,
        input_id = self.input_id,
        time     = self.time,
    }

    if s, ok := self.skill.?; ok {
        out.skill = skill_ref_clone(s, allocator)
    }

    return out
}

// Provider request/response protocol a turn was produced under. Closed set; the
// transport picks a decoder from it, and persisted provenance names it so a later
// replay can tell whether opaque provider data still applies.
Provider_Protocol :: enum {
    // Anthropic Messages.
    Anthropic_Messages,

    // OpenAI Chat Completions.
    Openai_Chat,

    // OpenAI Responses.
    Openai_Responses,
}

// Provider_Protocol <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
provider_protocol_wire := [Provider_Protocol]string {
    .Anthropic_Messages = "anthropic-messages",
    .Openai_Chat        = "openai-completions",
    .Openai_Responses   = "openai-responses",
}

// Wire string for a provider protocol.
provider_protocol_to_wire :: proc(p: Provider_Protocol) -> string {
    return provider_protocol_wire[p]
}

// Provider protocol for a wire string; ok is false for an unknown protocol.
provider_protocol_from_wire :: proc(s: string) -> (Provider_Protocol, bool) {
    return enum_from_wire(provider_protocol_wire, s)
}

// Which provider actually produced one assistant turn. Absent on a turn the daemon
// built before the field existed. `Assistant_Message.config_rev` records the
// configuration a turn was *requested* under and can be resolved away by a later
// config change; this records what answered, which is what makes provider-scoped
// opaque data (a reasoning part's signature) safe to replay: replay it only when
// the next request goes to the same protocol and model. Non-owning.
Turn_Provenance :: struct {
    // Protocol the turn was produced under.
    protocol: Provider_Protocol,

    // @bounded 128
    // Model id that produced the turn, resolved at request time.
    model:    string,
}

// Write a turn provenance object.
turn_provenance_emit :: proc(e: ^Emitter, self: Turn_Provenance) {
    object_begin(e)
    field_string(e, "protocol", provider_protocol_to_wire(self.protocol))
    field_string(e, "model", self.model)
    object_end(e)
}

// Verify annotated field bounds.
turn_provenance_validate :: proc(self: Turn_Provenance) -> Validation_Error {
    return enforce_bounded(128, self.model)
}

// Deep-copy into `allocator`.
turn_provenance_clone :: proc(self: Turn_Provenance, allocator := context.allocator) -> Turn_Provenance {
    return Turn_Provenance{protocol = self.protocol, model = strings.clone(self.model, allocator)}
}

// Decode a turn provenance object straight from the token stream.
turn_provenance_from_reader :: proc(d: ^Decoder) -> (out: Turn_Provenance, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Protocol,
        Model,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "protocol":
            out.protocol = dec_enum(d, provider_protocol_wire) or_return
            seen += {.Protocol}

        case "model":
            out.model = dec_string(d) or_return
            seen += {.Model}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Protocol, .Model} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Assistant transcript message payload. Non-owning.
Assistant_Message :: struct {
    // Message id.
    id:         Message_Id,

    // Owning run id.
    run_id:     Run_Id,

    // Resolves to a model string via session.config or config.changed.
    config_rev: Config_Rev,

    // @bounded 64
    // Agent name (`"main"` for a root session).
    agent:      string,

    // @bounded LIMITS.max_message_parts
    // Assistant parts in append order.
    content:    []Assistant_Part,

    // Present on every committed message; absent on a draft.
    finish:     Maybe(Stop_Reason),

    // Token accounting.
    tokens:     Maybe(Token_Usage),

    // Estimated United States dollars.
    cost:       Maybe(f64),

    // Creation/completion timestamps.
    time:       Message_Time,

    // Present exactly when `finish` is `"error"`.
    error:      Maybe(Message_Error),

    // Provider that produced this turn; absent on turns older than the field.
    provenance: Maybe(Turn_Provenance),
}

// Verify annotated field bounds.
assistant_message_validate :: proc(self: Assistant_Message) -> Validation_Error {
    enforce_bounded(64, self.agent) or_return

    if len(self.content) > LIMITS.max_message_parts {
        return .Overflow
    }

    for part, index in self.content {
        if u64(assistant_part_id(part)) != u64(index) {
            return .Mismatched_Payload
        }

        assistant_part_validate(part) or_return
    }

    if completed, ok := self.time.completed_at_ms.?; ok {
        if completed < self.time.created_at_ms {
            return .Mismatched_Payload
        }
    }

    if prov, ok := self.provenance.?; ok {
        turn_provenance_validate(prov) or_return
    }

    // Bounds the message so one always fits in a frame. A page of messages is the
    // sender's problem, not this bound's.
    if _assistant_message_string_bytes(self) > LIMITS.max_message_string_bytes {
        return .Overflow
    }

    return .None
}

// Validate the accumulated, not-yet-committed form used by resync.
assistant_message_validate_draft :: proc(self: Assistant_Message) -> Validation_Error {
    assistant_message_validate(self) or_return
    _, has_finish := self.finish.?
    _, has_tokens := self.tokens.?
    _, has_cost := self.cost.?
    _, has_completed := self.time.completed_at_ms.?
    _, has_error := self.error.?

    if has_finish || has_tokens || has_cost || has_completed || has_error {
        return .Mismatched_Payload
    }

    return .None
}

// Validate the finalized form stored in transcript history.
assistant_message_validate_committed :: proc(self: Assistant_Message) -> Validation_Error {
    assistant_message_validate(self) or_return
    finish, has_finish := self.finish.?

    if !has_finish {
        return .Mismatched_Payload
    }

    _, has_completed := self.time.completed_at_ms.?

    if !has_completed {
        return .Mismatched_Payload
    }
    // A structured error is present exactly when the message finished in error.
    me, has_error := self.error.?

    if (finish == .Error) != has_error {
        return .Mismatched_Payload
    }

    if has_error {
        message_error_validate(me) or_return
    }

    if cost, ok := self.cost.?; ok {
        // isFinite && >= 0: reject non-finite (exponent bits all ones) or negative.
        bits := transmute(u64)cost
        finite := (bits >> 52) & 0x7ff != 0x7ff

        if !finite || cost < 0 {
            return .Out_Of_Range
        }
    }

    return .None
}

// Write an assistant message object with `type` first.
assistant_message_emit :: proc(e: ^Emitter, self: Assistant_Message) {
    object_begin(e)
    field_string(e, "type", "assistant")
    field_u64(e, "id", u64(self.id))
    field_u64(e, "run_id", u64(self.run_id))
    field_u64(e, "config_rev", u64(self.config_rev))
    field_string(e, "agent", self.agent)
    key(e, "content")
    array_begin(e)
    for part in self.content {
        elem(e)
        assistant_part_emit(e, part)
    }

    array_end(e)

    if f, ok := self.finish.?; ok {
        field_string(e, "finish", stop_reason_to_wire(f))
    }

    if tok, ok := self.tokens.?; ok {
        key(e, "tokens")
        token_usage_emit(e, tok)
    }

    if c, ok := self.cost.?; ok {
        _field_f64(e, "cost", c)
    }

    key(e, "time")
    message_time_emit(e, self.time)

    if me, ok := self.error.?; ok {
        key(e, "error")
        message_error_emit(e, me)
    }

    if prov, ok := self.provenance.?; ok {
        key(e, "provenance")
        turn_provenance_emit(e, prov)
    }

    object_end(e)
}

// Deep-copy into `allocator`.
assistant_message_clone :: proc(self: Assistant_Message, allocator := context.allocator) -> Assistant_Message {
    parts := make([]Assistant_Part, len(self.content), allocator)
    for i in 0 ..< len(parts) {
        parts[i] = assistant_part_clone(self.content[i], allocator)
    }

    error: Maybe(Message_Error)

    if me, ok := self.error.?; ok {
        error = message_error_clone(me, allocator)
    }

    provenance: Maybe(Turn_Provenance)

    if prov, ok := self.provenance.?; ok {
        provenance = turn_provenance_clone(prov, allocator)
    }

    return Assistant_Message {
        id = self.id,
        run_id = self.run_id,
        config_rev = self.config_rev,
        agent = strings.clone(self.agent, allocator),
        content = parts,
        finish = self.finish,
        tokens = self.tokens,
        cost = self.cost,
        time = self.time,
        error = error,
        provenance = provenance,
    }
}

// Compaction transcript message payload. Non-owning.
Compaction_Message :: struct {
    // Message id.
    id:            Message_Id,

    // Owning run id.
    run_id:        Run_Id,

    // Why compaction ran.
    reason:        Compaction_Reason,

    // @unbounded
    // Model-generated summary of the dropped range.
    summary:       string,

    // @required-nullable
    // First message id still in the provider context. Null means nothing was kept.
    first_kept_id: Maybe(Message_Id),

    // Tokens before compaction.
    tokens_before: u64,

    // Tokens after compaction.
    tokens_after:  u64,

    // Creation timestamp.
    time:          Created_Time,
}

// Deep-copy into `allocator`.
compaction_message_clone :: proc(self: Compaction_Message, allocator := context.allocator) -> Compaction_Message {
    return Compaction_Message {
        id = self.id,
        run_id = self.run_id,
        reason = self.reason,
        summary = strings.clone(self.summary, allocator),
        first_kept_id = self.first_kept_id,
        tokens_before = self.tokens_before,
        tokens_after = self.tokens_after,
        time = self.time,
    }
}

// A transcript message. Non-owning.
Message :: union {
    // A user input message.
    User_Message,

    // An assistant round.
    Assistant_Message,

    // A compaction divider.
    Compaction_Message,
}

// Write internally-tagged JSON with `type` first.
message_emit :: proc(e: ^Emitter, self: Message) {
    switch v in self {
    case User_Message:
        object_begin(e)
        field_string(e, "type", "user")
        field_u64(e, "id", u64(v.id))
        key(e, "content")
        array_begin(e)
        for part in v.content {
            elem(e)
            content_part_emit(e, part)
        }

        array_end(e)
        field_u64(e, "input_id", u64(v.input_id))

        if s, ok := v.skill.?; ok {
            key(e, "skill")
            skill_ref_emit(e, s)
        }

        key(e, "time")
        created_time_emit(e, v.time)
        object_end(e)

    case Assistant_Message:
        assistant_message_emit(e, v)

    case Compaction_Message:
        object_begin(e)
        field_string(e, "type", "compaction")
        field_u64(e, "id", u64(v.id))
        field_u64(e, "run_id", u64(v.run_id))
        field_string(e, "reason", compaction_reason_to_wire(v.reason))
        field_string(e, "summary", v.summary)
        field_required_null_u64(e, "first_kept_id", v.first_kept_id)
        field_u64(e, "tokens_before", v.tokens_before)
        field_u64(e, "tokens_after", v.tokens_after)
        key(e, "time")
        created_time_emit(e, v.time)
        object_end(e)
    }
}

// Verify annotated field bounds.
message_validate :: proc(self: Message) -> Validation_Error {
    switch v in self {
    case User_Message:
        if len(v.content) > LIMITS.max_input_parts {
            return .Overflow
        }

        for part in v.content {
            content_part_validate(part) or_return
        }

        if s, ok := v.skill.?; ok {
            return skill_ref_validate(s)
        }

    case Assistant_Message:
        return assistant_message_validate_committed(v)

    case Compaction_Message:
    }

    return .None
}

// Deep-copy into `allocator`.
message_clone :: proc(self: Message, allocator := context.allocator) -> Message {
    switch v in self {
    case User_Message:
        return user_message_clone(v, allocator)

    case Assistant_Message:
        return assistant_message_clone(v, allocator)

    case Compaction_Message:
        return compaction_message_clone(v, allocator)
    }

    return nil
}

// Message id, whichever variant.
message_id :: proc(self: Message) -> Message_Id {
    switch v in self {
    case User_Message:
        return v.id

    case Assistant_Message:
        return v.id

    case Compaction_Message:
        return v.id
    }

    return 0
}

// ---------------------------------------------------------------------------
// Private codec helpers
// ---------------------------------------------------------------------------

// Write a display-only view array field.
@(private)
_emit_view_slice :: proc(e: ^Emitter, name: string, views: []View) {
    key(e, name)
    array_begin(e)
    for v in views {
        elem(e)
        view_emit(e, v)
    }

    array_end(e)
}

// Write a Permission_State, omitting absent optionals.
@(private)
_permission_state_emit :: proc(e: ^Emitter, self: Permission_State) {
    object_begin(e)
    field_u64(e, "requested_at_ms", self.requested_at_ms)

    if opts, ok := self.options.?; ok {
        key(e, "options")
        array_begin(e)
        for opt in opts {
            elem(e)
            _permission_option_emit(e, opt)
        }

        array_end(e)
    }

    if dec, ok := self.decision.?; ok {
        key(e, "decision")
        permission_decision_emit(e, dec)
    }

    object_end(e)
}

// Write a Permission_Option, omitting absent optionals.
@(private)
_permission_option_emit :: proc(e: ^Emitter, self: Permission_Option) {
    object_begin(e)
    field_string(e, "id", self.id)
    field_string(e, "kind", permission_option_kind_to_wire(self.kind))
    field_string(e, "label", self.label)

    if creates, ok := self.creates.?; ok {
        key(e, "creates")
        array_begin(e)
        for pattern in creates {
            elem(e)
            val_string(e, pattern)
        }

        array_end(e)
    }

    object_end(e)
}

// Count the payload string bytes retained by an assistant draft: the agent plus
// every content part's reachable strings. Replaces Zig's reflection walk.
// Excludes the elided constant discriminators and the nested Client provenance
// strings on a user permission decision (bounded, non-payload).
@(private)
_assistant_message_string_bytes :: proc(self: Assistant_Message) -> int {
    total := len(self.agent)
    for part in self.content {
        total += _assistant_part_string_bytes(part)
    }

    return total
}

@(private)
_assistant_part_string_bytes :: proc(self: Assistant_Part) -> int {
    switch v in self {
    case Text_Part:
        return len(v.text)

    case Reasoning_Part:
        return len(v.text) + len(v.signature)

    case Tool_Part:
        total := len(v.name) + len(v.arguments)

        if c, ok := v.call_id.?; ok {
            total += len(c)
        }

        if views, ok := v.input_view.?; ok {
            for view in views {
                total += _view_string_bytes(view)
            }
        }

        total += _tool_state_string_bytes(v.state)

        if p, ok := v.permission_state.?; ok {
            total += _permission_state_string_bytes(p)
        }

        return total
    }

    return 0
}

@(private)
_tool_state_string_bytes :: proc(self: Tool_State) -> int {
    switch v in self {
    case Tool_State_Pending, Tool_State_Waiting_Permission, Tool_State_Canceled:
        return 0

    case Tool_State_Running:
        if out, ok := v.output.?; ok {
            return len(out)
        }

        return 0

    case Tool_State_Completed:
        total := len(v.output)

        if views, ok := v.view.?; ok {
            for view in views {
                total += _view_string_bytes(view)
            }
        }

        return total

    case Tool_State_Error:
        total := len(v.message)

        if views, ok := v.view.?; ok {
            for view in views {
                total += _view_string_bytes(view)
            }
        }

        return total

    case Tool_State_Denied:
        return len(v.reason)
    }

    return 0
}

@(private)
_permission_state_string_bytes :: proc(self: Permission_State) -> int {
    total := 0

    if opts, ok := self.options.?; ok {
        for opt in opts {
            total += len(opt.id) + len(opt.label)

            if creates, cok := opt.creates.?; cok {
                for pattern in creates {
                    total += len(pattern)
                }
            }
        }
    }

    if dec, ok := self.decision.?; ok {
        switch d in dec {
        case Permission_Decision_User:
            total += len(d.option_id) + len(d.label)

        case Permission_Decision_Rule:
            total += len(d.label)
        }
    }

    return total
}

// --- streaming decoders ---

// Decode creation/completion timestamps straight from the token stream.
message_time_from_reader :: proc(d: ^Decoder) -> (time: Message_Time, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Created,
        Completed,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "created_at_ms":
            time.created_at_ms = dec_u64(d) or_return
            seen += {.Created}

        case "completed_at_ms":
            seen += {.Completed}

            if !dec_is_null(d) {
                time.completed_at_ms = dec_u64(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Created, .Completed} {
        return {}, .Mismatched_Payload
    }

    return time, .None
}

// Decode a creation timestamp straight from the token stream.
created_time_from_reader :: proc(d: ^Decoder) -> (time: Created_Time, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "created_at_ms":
            time.created_at_ms = dec_u64(d) or_return
            have = true

        case "completed_at_ms":
            return {}, .Mismatched_Payload

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return time, .None
}

// Decode a structured message error straight from the token stream.
message_error_from_reader :: proc(d: ^Decoder) -> (me: Message_Error, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Type,
        Message,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "type":
            me.type = dec_string(d) or_return
            seen += {.Type}

        case "message":
            me.message = dec_string(d) or_return
            seen += {.Message}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Type, .Message} {
        return {}, .Mismatched_Payload
    }

    return me, .None
}

// Decode a Permission_State straight from the token stream (local-only fold).
_permission_state_from_reader :: proc(d: ^Decoder) -> (ps: Permission_State, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Req,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "requested_at_ms":
            ps.requested_at_ms = dec_u64(d) or_return
            seen += {.Req}

        case "options":
            ps.options = dec_array(d, permission_option_from_reader) or_return

        case "decision":
            ps.decision = permission_decision_from_reader(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if .Req not_in seen {
        return {}, .Mismatched_Payload
    }

    return ps, .None
}

// Decode internally-tagged assistant part straight from the token stream.
assistant_part_from_reader :: proc(d: ^Decoder) -> (part: Assistant_Part, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "text":
        id: u64
        text: string

        Field :: enum {
            Id,
            Text,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "id":
                id = dec_u64(d) or_return
                seen += {.Id}

            case "text":
                text = dec_string(d) or_return
                seen += {.Text}

            case "call_id", "name", "arguments", "input_view", "state", "permission", "signature":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Id, .Text} {
            return nil, .Mismatched_Payload
        }

        return Text_Part{id = Part_Id(id), text = text}, .None

    case "reasoning":
        id: u64
        text: string
        signature: string

        Field :: enum {
            Id,
            Text,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "id":
                id = dec_u64(d) or_return
                seen += {.Id}

            case "text":
                text = dec_string(d) or_return
                seen += {.Text}

            // Optional: rows written before the field existed carry no signature.
            case "signature":
                signature = dec_string(d) or_return

            case "call_id", "name", "arguments", "input_view", "state", "permission":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Id, .Text} {
            return nil, .Mismatched_Payload
        }

        return Reasoning_Part{id = Part_Id(id), text = text, signature = signature}, .None

    case "tool":
        tp: Tool_Part

        Field :: enum {
            Id,
            Name,
            Args,
            State,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "id":
                tp.id = Part_Id(dec_u64(d) or_return)
                seen += {.Id}

            case "call_id":
                tp.call_id = dec_string(d) or_return

            case "name":
                tp.name = dec_string(d) or_return
                seen += {.Name}

            case "arguments":
                tp.arguments = dec_string(d) or_return
                seen += {.Args}

            case "input_view":
                tp.input_view = dec_array(d, view_from_reader) or_return

            case "state":
                tp.state = tool_state_from_reader(d) or_return
                seen += {.State}

            case "permission":
                tp.permission_state = _permission_state_from_reader(d) or_return

            case "text":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Id, .Name, .Args, .State} {
            return nil, .Mismatched_Payload
        }

        return tp, .None
    }

    return nil, .Mismatched_Payload
}

// Decode internally-tagged tool state straight from the token stream.
tool_state_from_reader :: proc(d: ^Decoder) -> (state: Tool_State, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "pending":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "started_at_ms", "permission", "output", "error", "view", "duration_ms", "reason", "denied_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Tool_State_Pending{}, .None

    case "waiting_permission":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "started_at_ms", "permission", "output", "error", "view", "duration_ms", "reason", "denied_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Tool_State_Waiting_Permission{}, .None

    case "running":
        st: Tool_State_Running

        Field :: enum {
            Start,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "started_at_ms":
                st.started_at_ms = dec_u64(d) or_return
                seen += {.Start}

            case "output":
                st.output = dec_string(d) or_return

            case "permission", "error", "view", "duration_ms", "reason", "denied_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if .Start not_in seen {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "completed":
        st: Tool_State_Completed

        Field :: enum {
            Output,
            Dur,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "output":
                st.output = dec_string(d) or_return
                seen += {.Output}

            case "view":
                st.view = dec_array(d, view_from_reader) or_return

            case "duration_ms":
                st.duration_ms = dec_u64(d) or_return
                seen += {.Dur}

            case "permission", "started_at_ms", "error", "reason", "denied_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Output, .Dur} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "error":
        st: Tool_State_Error

        Field :: enum {
            Msg,
            Dur,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "error":
                st.message = dec_string(d) or_return
                seen += {.Msg}

            case "view":
                st.view = dec_array(d, view_from_reader) or_return

            case "duration_ms":
                st.duration_ms = dec_u64(d) or_return
                seen += {.Dur}

            case "permission", "started_at_ms", "output", "reason", "denied_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Msg, .Dur} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "denied":
        st: Tool_State_Denied

        Field :: enum {
            Reason,
            By,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "reason":
                st.reason = dec_string(d) or_return
                seen += {.Reason}

            case "denied_by":
                st.denied_by = dec_enum(d, denied_by_wire) or_return
                seen += {.By}

            case "permission", "started_at_ms", "output", "error", "view", "duration_ms":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Reason, .By} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "canceled":
        st: Tool_State_Canceled
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "duration_ms":
                have = true

                if !dec_is_null(d) {
                    st.duration_ms = dec_u64(d) or_return
                }

            case "permission", "started_at_ms", "output", "error", "view", "reason", "denied_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return st, .None
    }

    return nil, .Mismatched_Payload
}

// Read the assistant message body (fields after `type` was consumed).
_assistant_message_body :: proc(d: ^Decoder) -> (msg: Assistant_Message, err: Validation_Error) {
    Field :: enum {
        Id,
        Run,
        Cfg,
        Agent,
        Content,
        Time,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            msg.id = Message_Id(dec_u64(d) or_return)
            seen += {.Id}

        case "run_id":
            msg.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case "config_rev":
            msg.config_rev = Config_Rev(dec_u64(d) or_return)
            seen += {.Cfg}

        case "agent":
            msg.agent = dec_string(d) or_return
            seen += {.Agent}

        case "content":
            msg.content = dec_array(d, assistant_part_from_reader) or_return
            seen += {.Content}

        case "finish":
            msg.finish = dec_enum(d, stop_reason_wire) or_return

        case "tokens":
            msg.tokens = token_usage_from_reader(d) or_return

        case "cost":
            msg.cost = dec_f64(d) or_return

        case "time":
            msg.time = message_time_from_reader(d) or_return
            seen += {.Time}

        case "error":
            msg.error = message_error_from_reader(d) or_return

        // Persisted-only and optional: rows written before the field existed, and
        // every message a client ever sees, carry no provenance.
        case "provenance":
            msg.provenance = turn_provenance_from_reader(d) or_return

        case "input_id", "skill", "reason", "summary", "first_kept_id", "tokens_before", "tokens_after":
            return {}, .Mismatched_Payload

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Run, .Cfg, .Agent, .Content, .Time} {
        return {}, .Mismatched_Payload
    }

    return msg, .None
}

// Decode an assistant message straight from the token stream (any member order).
// Shared by the Message union and by the resync active-draft path.
assistant_message_from_reader :: proc(d: ^Decoder) -> (msg: Assistant_Message, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    if tag != "assistant" {
        return {}, .Mismatched_Payload
    }

    return _assistant_message_body(d)
}

// Read the user message body (fields after `type` was consumed).
_user_message_body :: proc(d: ^Decoder) -> (msg: User_Message, err: Validation_Error) {
    Field :: enum {
        Id,
        Content,
        Input,
        Time,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            msg.id = Message_Id(dec_u64(d) or_return)
            seen += {.Id}

        case "content":
            msg.content = dec_array(d, content_part_from_reader) or_return
            seen += {.Content}

        case "input_id":
            msg.input_id = Input_Id(dec_u64(d) or_return)
            seen += {.Input}

        case "skill":
            msg.skill = skill_ref_from_reader(d) or_return

        case "time":
            msg.time = created_time_from_reader(d) or_return
            seen += {.Time}

        case "run_id",
             "config_rev",
             "agent",
             "finish",
             "tokens",
             "cost",
             "reason",
             "summary",
             "first_kept_id",
             "tokens_before",
             "tokens_after",
             "error",
             "provenance":
            return {}, .Mismatched_Payload

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Content, .Input, .Time} {
        return {}, .Mismatched_Payload
    }

    return msg, .None
}

// Read the compaction message body (fields after `type` was consumed).
_compaction_message_body :: proc(d: ^Decoder) -> (msg: Compaction_Message, err: Validation_Error) {
    Field :: enum {
        Id,
        Run,
        Reason,
        Summary,
        Fk,
        Tb,
        Ta,
        Time,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            msg.id = Message_Id(dec_u64(d) or_return)
            seen += {.Id}

        case "run_id":
            msg.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case "reason":
            msg.reason = dec_enum(d, compaction_reason_wire) or_return
            seen += {.Reason}

        case "summary":
            msg.summary = dec_string(d) or_return
            seen += {.Summary}

        case "first_kept_id":
            seen += {.Fk}

            if !dec_is_null(d) {
                msg.first_kept_id = Message_Id(dec_u64(d) or_return)
            }

        case "tokens_before":
            msg.tokens_before = dec_u64(d) or_return
            seen += {.Tb}

        case "tokens_after":
            msg.tokens_after = dec_u64(d) or_return
            seen += {.Ta}

        case "time":
            msg.time = created_time_from_reader(d) or_return
            seen += {.Time}

        case "content", "input_id", "skill", "config_rev", "agent", "finish", "tokens", "cost", "error", "provenance":
            return {}, .Mismatched_Payload

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Run, .Reason, .Summary, .Fk, .Tb, .Ta, .Time} {
        return {}, .Mismatched_Payload
    }

    return msg, .None
}

// Decode internally-tagged transcript message straight from the token stream.
message_from_reader :: proc(d: ^Decoder) -> (msg: Message, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "user":
        um := _user_message_body(d) or_return
        return um, .None

    case "assistant":
        am := _assistant_message_body(d) or_return
        return am, .None

    case "compaction":
        cm := _compaction_message_body(d) or_return
        return cm, .None
    }

    return nil, .Mismatched_Payload
}
