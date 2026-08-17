package client

import "core:mem"
import "core:strings"
import "src:wire"

// Largest committed window retained live; older messages fall off.
MAX_RETAINED_MESSAGES :: wire.LIMITS.max_page_size

// Failure modes surfaced by the fallible replica procedures. `None` is success.
Replica_Error :: enum {
    None = 0,
    Session_Mismatch,
    Malformed_Snapshot,
    Config_Revision_Conflict,
}

// Observable outcome of applying one broadcast.
Apply_Kind :: enum {
    // Duplicate, stale, unrelated, or otherwise state-neutral.
    Ignored,

    // Visible state changed.
    Changed,

    // The matching active draft was discarded.
    Discarded,

    // A message committed and sealed.
    Committed,

    // A discontinuity requires the owning controller to resync.
    Gap,
}

// Result of applying one broadcast. `message_id` is meaningful only for `.Discarded`
// and `.Committed`.
Apply_Result :: struct {
    kind:       Apply_Kind,
    message_id: wire.Message_Id,
}

// Kind of one active assistant part. Text and visible reasoning share the
// `Text_Buffer` payload; redacted reasoning remains opaque and immutable.
Part_Kind :: enum {
    Text,
    Reasoning,
    Redacted_Reasoning,
    Tool,
}

// Accumulated bytes for a text or reasoning part.
Text_Buffer :: struct {
    // Ordinal of this part within the message.
    id:    wire.Part_Id,

    // Folded UTF-8 bytes, owned by the draft arena.
    bytes: [dynamic]u8,
}

// A tool part plus the display output it streams while running.
Tool_Buffer :: struct {
    // Tool invocation; name, arguments, and state owned by the draft arena.
    tool:   wire.Tool_Part,

    // Display output folded from `tool.output_delta` while running, owned by the draft
    // arena. Its UTF-8 byte length is the next delta's offset baseline.
    output: [dynamic]u8,
}

// One owned part of the active draft. A union discriminates by type, so text and
// reasoning (both `Text_Buffer`) cannot be separate arms; a `kind` tag selects instead.
Active_Part :: struct {
    kind:     Part_Kind,
    text:     Text_Buffer, // used for `.Text` and `.Reasoning`
    redacted: wire.Redacted_Reasoning_Part, // used for `.Redacted_Reasoning`
    tool:     Tool_Buffer, // used for `.Tool`; owned by the draft arena
}

// One accumulated assistant draft and the arena owning its bytes.
Draft_Replica :: struct {
    // Arena owning `agent`, all part bytes, and nested tool data.
    arena:         mem.Dynamic_Arena,

    // Id of this message.
    message_id:    wire.Message_Id,

    // Run the message belongs to.
    run_id:        wire.Run_Id,

    // Config revision the message was produced under.
    config_rev:    wire.Config_Rev,

    // Agent name, owned by the arena.
    agent:         string,

    // Wall-clock creation time, milliseconds.
    created_at_ms: u64,

    // Parts in arrival order, backed by the arena.
    parts:         [dynamic]Active_Part,
}

// A committed message and the arena owning its slices. Keyed by id.
Owned_Message :: struct {
    // Arena owning `message`'s slices.
    arena:   mem.Dynamic_Arena,

    // Committed message; slices point into `arena`.
    message: wire.Message,
}

// One queued input and the arena owning its content.
Owned_Queued_Input :: struct {
    // Arena owning `input`'s slices.
    arena: mem.Dynamic_Arena,

    // Queued input; slices point into `arena`.
    input: wire.Queued_Input,
}

// Replica-local pending-permission view. The resync snapshot carries no pending-permission
// field, so this is derived from the active draft's tool state. All borrowed fields point
// into the draft arena and die with the draft.
Pending_Permission_View :: struct {
    message_id:      wire.Message_Id,
    part_id:         wire.Part_Id,
    tool_name:       string,
    arguments:       string,
    options:         []wire.Permission_Option,
    requested_at_ms: u64,
}

// Borrowed active-draft metadata. `agent` points into the draft arena and is invalidated
// by any operation that ends or replaces the draft, or by `replica_destroy`.
Active_Info :: struct {
    message_id:    wire.Message_Id,
    run_id:        wire.Run_Id,
    config_rev:    wire.Config_Rev,
    agent:         string,
    created_at_ms: u64,
    part_count:    int,
}

// Owned state for one session. Ids are keys, never indices; `highest_finalized_id` is
// the seal boundary. Synchronization belongs to the connection/session controller; the
// replica only folds live broadcasts and atomically installs resync cuts.
Session_Replica :: struct {
    // @private
    // Backing allocator; block allocator for every region arena.
    allocator:               mem.Allocator,

    // Session this replica owns.
    session_id:              wire.Session_Id,

    // Currently open draft, or nil.
    active:                  ^Draft_Replica,

    // High-water mark of committed or discarded ids; lower ids are finalized.
    highest_finalized_id:    Maybe(wire.Message_Id),

    // Highest durable seq represented.
    base_seq:                wire.Seq,

    // Committed window, oldest first, unique by id.
    messages:                [dynamic]Owned_Message,

    // Older committed messages exist beyond `messages`.
    has_more:                bool,

    // Configs keyed by immutable `config_rev`; strings in `configs_arena`. Retained for the
    // whole session lifetime — immutable and referenced by committed messages — and
    // reclaimed only on snapshot install or deinit; entries are never individually evicted.
    configs:                 [dynamic]wire.Run_Config,

    // @private
    // Owns `configs` strings; reset on install.
    configs_arena:           mem.Dynamic_Arena,

    // Pending manual compaction run.
    pending_compaction:      Maybe(wire.Run_Id),

    // Run id most recently cleared by a durable `run.done`/compaction start. Since run ids
    // are never reused, it lets a stale `session.activity` be recognized and stopped from
    // re-asserting a compaction the durable stream already cleared. Reset on install.
    last_cleared_compaction: Maybe(wire.Run_Id),

    // Queued inputs, each independently reclaimable.
    queued:                  [dynamic]Owned_Queued_Input,
}

// Initialize an empty replica for `session_id`. `allocator` backs every region arena and
// dynamic-array spine.
replica_init :: proc(self: ^Session_Replica, allocator: mem.Allocator, session_id: wire.Session_Id) {
    self^ = {}
    self.allocator = allocator
    self.session_id = session_id
    mem.dynamic_arena_init(&self.configs_arena, allocator, allocator)
    self.messages = make([dynamic]Owned_Message, 0, allocator)
    self.configs = make([dynamic]wire.Run_Config, 0, allocator)
    self.queued = make([dynamic]Owned_Queued_Input, 0, allocator)
}

// Free the swappable owned state: active draft, committed messages, configs, and queued
// inputs, plus their spines. Mirrors the teardown in the install commit step; keep the two
// sites freeing identical field sets.
replica_free_owned :: proc(self: ^Session_Replica) {
    if self.active != nil {
        draft_destroy(self.allocator, self.active)
        self.active = nil
    }

    for &owned in self.messages {
        owned_message_destroy(&owned)
    }
    delete(self.messages)

    delete(self.configs)
    mem.dynamic_arena_destroy(&self.configs_arena)

    for &owned in self.queued {
        owned_queued_input_destroy(&owned)
    }
    delete(self.queued)
}

// Free all owned state and zero the replica.
replica_destroy :: proc(self: ^Session_Replica) {
    replica_free_owned(self)

    self^ = {}
}

// Destroy a draft: free its arena, then the heap-allocated struct.
draft_destroy :: proc(allocator: mem.Allocator, draft: ^Draft_Replica) {
    mem.dynamic_arena_destroy(&draft.arena)
    free(draft, allocator)
}

// Clone `src` into a fresh per-message arena backed by `backing`. `wire.message_clone`
// cannot signal OOM, so this cannot fail; the arena is the sole free mechanism. The arena
// is initialized in the return-value slot and moved out by value; `Dynamic_Arena` holds no
// self-referential pointers, so the move is safe, and no allocator derived from its address
// is retained past this call.
owned_message_clone :: proc(src: wire.Message, backing: mem.Allocator) -> (owned: Owned_Message) {
    mem.dynamic_arena_init(&owned.arena, backing, backing)
    a := mem.dynamic_arena_allocator(&owned.arena)
    owned.message = wire.message_clone(src, a)

    return
}

// Free a committed message's arena.
owned_message_destroy :: proc(owned: ^Owned_Message) {
    mem.dynamic_arena_destroy(&owned.arena)
}

// Clone `src` into a fresh per-input arena backed by `backing`. `wire.queued_input_clone`
// cannot signal OOM, so this cannot fail; the arena is the sole free mechanism. See
// `owned_message_clone` for why moving the returned value out is safe.
owned_queued_input_clone :: proc(src: wire.Queued_Input, backing: mem.Allocator) -> (owned: Owned_Queued_Input) {
    mem.dynamic_arena_init(&owned.arena, backing, backing)
    a := mem.dynamic_arena_allocator(&owned.arena)
    owned.input = wire.queued_input_clone(src, a)

    return
}

// Free a queued input's arena.
owned_queued_input_destroy :: proc(owned: ^Owned_Queued_Input) {
    mem.dynamic_arena_destroy(&owned.arena)
}

// --- live folding ---

// Fold `message.started`, ignoring duplicate or stale starts.
replica_on_started :: proc(
    self: ^Session_Replica,
    data: wire.Message_Started_Data,
) -> (
    result: Apply_Result,
    err: Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    if is_finalized(self, data.message_id) {
        return {kind = .Ignored}, .None
    }

    if self.active != nil {
        if self.active.message_id == data.message_id {
            return {kind = .Ignored}, .None
        }

        return {kind = .Gap}, .None
    }

    draft := draft_from_started(self, data) or_return

    self.active = draft

    return {kind = .Changed}, .None
}

// Fold an append-only part announcement at its ordinal.
replica_on_part_added :: proc(
    self: ^Session_Replica,
    data: wire.Message_Part_Added_Data,
) -> (
    result: Apply_Result,
    err: Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    draft := open_draft(self, data.message_id)
    if draft == nil {
        return {kind = is_finalized(self, data.message_id) ? .Ignored : .Gap}, .None
    }

    ordinal := u64(wire.assistant_part_id(data.part))
    count := u64(len(draft.parts))

    if ordinal < count {
        return {kind = .Ignored}, .None // duplicated
    }

    if ordinal > count {
        return {kind = .Gap}, .None // missing part
    }

    if tool, is_tool := data.part.(wire.Tool_Part); is_tool {
        if _, is_waiting := tool.state.(wire.Tool_State_Waiting_Permission); is_waiting {
            if draft_has_waiting_permission(draft, nil) {
                return {kind = .Gap}, .None
            }
        }
    }

    arena_alloc := mem.dynamic_arena_allocator(&draft.arena)
    part := active_part_from_wire(data.part, arena_alloc) or_return

    append(&draft.parts, part)

    return {kind = .Changed}, .None
}

// Fold bytes per the `wire.Part_Delta` offset contract.
replica_on_part_delta :: proc(
    self: ^Session_Replica,
    data: wire.Message_Part_Delta_Data,
) -> (
    Apply_Result,
    Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    draft := open_draft(self, data.message_id)
    if draft == nil {
        return {kind = is_finalized(self, data.message_id) ? .Ignored : .Gap}, .None
    }

    index, ok := to_index(u64(data.part_id))
    if !ok || index >= len(draft.parts) {
        return {kind = .Gap}, .None
    }

    part := &draft.parts[index]

    // Only text and visible reasoning parts carry a byte buffer.
    if part.kind != .Text && part.kind != .Reasoning {
        return {kind = .Gap}, .None
    }

    offset, ook := to_index(data.offset)
    if !ook {
        return {kind = .Gap}, .None
    }

    have := len(part.text.bytes)

    if offset < have {
        return {kind = .Ignored}, .None // already present
    }

    if offset > have {
        return {kind = .Gap}, .None // missed a delta
    }

    append(&part.text.bytes, data.delta)

    return {kind = .Changed}, .None
}

// Fold bytes per the `wire.Part_Delta` offset contract, mirroring `replica_on_part_delta`.
// Output only streams while a tool part is `running`; a delta for a tool that already
// reached a terminal state is a straggler whose output is final, so it is ignored rather
// than resynced (a snapshot that sealed the tool would otherwise loop). The accumulated
// buffer is bounded by `wire.LIMITS.max_tool_output_stream_bytes`.
replica_on_tool_output_delta :: proc(
    self: ^Session_Replica,
    data: wire.Tool_Output_Delta_Data,
) -> (
    Apply_Result,
    Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    draft := open_draft(self, data.message_id)
    if draft == nil {
        return {kind = is_finalized(self, data.message_id) ? .Ignored : .Gap}, .None
    }

    index, ok := to_index(u64(data.part_id))
    if !ok || index >= len(draft.parts) {
        return {kind = .Gap}, .None
    }

    part := &draft.parts[index]

    // Output deltas only target tool parts.
    if part.kind != .Tool {
        return {kind = .Gap}, .None
    }

    if _, is_running := part.tool.tool.state.(wire.Tool_State_Running); !is_running {
        return {kind = .Ignored}, .None
    }

    offset, ook := to_index(data.offset)
    if !ook {
        return {kind = .Gap}, .None
    }

    have := len(part.tool.output)

    if offset < have {
        return {kind = .Ignored}, .None // already present
    }

    if offset > have {
        return {kind = .Gap}, .None // missed a delta
    }

    // The client cap matches the daemon's; exceeding it is a protocol violation, handled
    // like an offset gap so the same class-`.Live_Droppable` resync path recovers.
    if have + len(data.delta) > wire.LIMITS.max_tool_output_stream_bytes {
        return {kind = .Gap}, .None
    }

    append(&part.tool.output, data.delta)

    return {kind = .Changed}, .None
}

// Replace the full live state of an existing tool part.
replica_on_tool_state_changed :: proc(
    self: ^Session_Replica,
    data: wire.Tool_State_Changed_Data,
) -> (
    Apply_Result,
    Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    draft := open_draft(self, data.message_id)
    if draft == nil {
        return {kind = is_finalized(self, data.message_id) ? .Ignored : .Gap}, .None
    }

    index, ok := to_index(u64(data.part_id))
    if !ok || index >= len(draft.parts) {
        return {kind = .Gap}, .None
    }

    part := &draft.parts[index]
    if part.kind != .Tool {
        return {kind = .Gap}, .None
    }

    // A stale broadcast must not regress a terminal tool part back to an active state.
    if tool_state_is_terminal(part.tool.tool.state) && !tool_state_is_terminal(data.state) {
        return {kind = .Ignored}, .None
    }

    if _, is_waiting := data.state.(wire.Tool_State_Waiting_Permission); is_waiting {
        perm, has_perm := data.permission_state.?

        // A resolution must not leave the state in waiting_permission.
        if !has_perm || !permission_state_is_awaiting(perm) {
            return {kind = .Gap}, .None
        }

        if draft_has_waiting_permission(draft, data.part_id) {
            return {kind = .Gap}, .None
        }
    }

    // Previous tool state is owned by the draft arena; replaced in place. The superseded
    // clone is not freed until draft teardown (a Dynamic_Arena has no per-object free).
    arena_alloc := mem.dynamic_arena_allocator(&draft.arena)
    part.tool.tool.state = wire.tool_state_clone(data.state, arena_alloc)
    part.tool.tool.permission_state = nil

    if p, has_permission := data.permission_state.?; has_permission {
        part.tool.tool.permission_state = wire.permission_state_clone(p, arena_alloc)
    }

    return {kind = .Changed}, .None
}

// Apply the tombstone for an abandoned draft. Idempotent: unknown or finalized ids do not
// damage another open draft and do not demand resync.
replica_on_discarded :: proc(self: ^Session_Replica, data: wire.Message_Discarded_Data) -> Apply_Result {
    if self.session_id != data.session_id {
        return {kind = .Ignored}
    }

    if self.active != nil && self.active.message_id == data.message_id {
        advance_finalized(self, data.message_id)
        drop_active(self)

        return {kind = .Discarded, message_id = data.message_id}
    }

    return {kind = .Ignored}
}

// --- live-folding helpers ---

// Create an empty draft from a live `message.started`. The heap-allocated struct and its
// arena diverge from the Zig inline optional; the arena owns `agent` and all part bytes.
// On failure everything is rolled back and nil is returned.
draft_from_started :: proc(
    self: ^Session_Replica,
    data: wire.Message_Started_Data,
) -> (
    ^Draft_Replica,
    Replica_Error,
) {
    d := new(Draft_Replica, self.allocator)

    mem.dynamic_arena_init(&d.arena, self.allocator, self.allocator)
    arena_alloc := mem.dynamic_arena_allocator(&d.arena)

    parts := make([dynamic]Active_Part, 0, arena_alloc)

    d.message_id = data.message_id
    d.run_id = data.run_id
    d.config_rev = data.config_rev
    d.created_at_ms = data.created_at_ms
    d.agent = strings.clone(data.agent, arena_alloc)
    d.parts = parts

    return d, .None
}

// Build a text/reasoning byte buffer in the draft arena, folding the initial bytes.
text_buffer_build :: proc(id: wire.Part_Id, text: string, allocator: mem.Allocator) -> Text_Buffer {
    bytes := make([dynamic]u8, 0, allocator)
    append(&bytes, text)

    return {id = id, bytes = bytes}
}

// Build one active-draft part from a wire assistant part, shared by live part-added folding
// and resync snapshot reconstruction. A tool part's output buffer starts empty; a caller
// seeding it from a running tool's already-streamed output (resync only) does so after this
// returns.
active_part_from_wire :: proc(
    part: wire.Assistant_Part,
    allocator: mem.Allocator,
) -> (
    result: Active_Part,
    err: Replica_Error,
) {
    switch v in part {
    case wire.Text_Part:
        buf := text_buffer_build(v.id, v.text, allocator)

        return {kind = .Text, text = buf}, .None

    case wire.Reasoning_Part:
        buf := text_buffer_build(v.id, v.text, allocator)

        return {kind = .Reasoning, text = buf}, .None

    case wire.Redacted_Reasoning_Part:
        redacted := wire.Redacted_Reasoning_Part {
            id   = v.id,
            data = strings.clone(v.data, allocator),
        }

        return {kind = .Redacted_Reasoning, redacted = redacted}, .None

    case wire.Tool_Part:
        // `wire.tool_part_clone` cannot signal OOM, and the output buffer only records its
        // arena allocator (no allocation) here, so this arm never fails mid-build.
        buf: Tool_Buffer
        buf.tool = wire.tool_part_clone(v, allocator)
        buf.output.allocator = allocator

        return {kind = .Tool, tool = buf}, .None
    }

    return {}, .None
}

// Pointer to the active draft if `message_id` matches, else nil.
open_draft :: proc(self: ^Session_Replica, message_id: wire.Message_Id) -> ^Draft_Replica {
    if self.active != nil && self.active.message_id == message_id {
        return self.active
    }

    return nil
}

// Whether another tool in `draft` is waiting for permission. `except` excludes the part
// being transitioned in place.
draft_has_waiting_permission :: proc(draft: ^Draft_Replica, except: Maybe(wire.Part_Id)) -> bool {
    assert(draft != nil, "permission scan needs a draft")

    for &part in draft.parts {
        if part.kind != .Tool {
            continue
        }

        if part_id, ok := except.?; ok && part.tool.tool.id == part_id {
            continue
        }

        if _, is_waiting := part.tool.tool.state.(wire.Tool_State_Waiting_Permission); is_waiting {
            return true
        }
    }

    return false
}

// True if `message_id` is at or below the finalized high-water mark.
is_finalized :: proc(self: ^Session_Replica, message_id: wire.Message_Id) -> bool {
    if highest, ok := self.highest_finalized_id.?; ok {
        return message_id <= highest
    }

    return false
}

// Raise the finalized high-water mark to `message_id` if it is higher.
advance_finalized :: proc(self: ^Session_Replica, message_id: wire.Message_Id) {
    highest, ok := self.highest_finalized_id.?
    if !ok || message_id > highest {
        self.highest_finalized_id = message_id
    }
}

// Destroy and clear the active draft.
drop_active :: proc(self: ^Session_Replica) {
    if self.active != nil {
        draft_destroy(self.allocator, self.active)
        self.active = nil
    }
}

// Pointer to part `part_id`, or nil if the draft or part is absent. Part ids are ordinals.
part_at :: proc(self: ^Session_Replica, part_id: wire.Part_Id) -> ^Active_Part {
    if self.active == nil {
        return nil
    }

    index, ok := to_index(u64(part_id))
    if !ok || index >= len(self.active.parts) {
        return nil
    }

    return &self.active.parts[index]
}

// The draft part an activity locator names, or nil when the replica cannot compare against
// it: no draft for that message, or an ordinal it has not folded yet.
located_part :: proc(self: ^Session_Replica, message_id: wire.Message_Id, part_id: wire.Part_Id) -> ^Active_Part {
    if open_draft(self, message_id) == nil {
        return nil
    }

    part := part_at(self, part_id)

    if part == nil {
        return nil
    }

    stored_id: wire.Part_Id

    switch part.kind {
    case .Text, .Reasoning:
        stored_id = part.text.id

    case .Redacted_Reasoning:
        stored_id = part.redacted.id

    case .Tool:
        stored_id = part.tool.tool.id
    }

    assert(stored_id == part_id, "draft part stored off its ordinal")

    return part
}

// True when an activity's locators contradict the replica's own derived draft state.
// Only an identity conflict at a part the replica already holds proves divergence — a
// missing draft or unfolded ordinal means the unsequenced streams are out of step.
activity_locators_diverge :: proc(self: ^Session_Replica, state: wire.Activity_State) -> bool {
    assert(self != nil, "locator comparison needs a replica")

    #partial switch v in state {
    case wire.Activity_State_Reasoning:
        part := located_part(self, v.message_id, v.part_id)

        return part != nil && part.kind != .Reasoning

    case wire.Activity_State_Waiting_Permission:
        part := located_part(self, v.message_id, v.part_id)

        return part != nil && (part.kind != .Tool || part.tool.tool.name != v.tool_name)

    case wire.Activity_State_Running_Tool:
        part := located_part(self, v.message_id, v.part_id)

        return part != nil && (part.kind != .Tool || part.tool.tool.name != v.tool_name)
    }

    return false
}

// A terminal tool state never transitions back to an active state; a broadcast that would
// regress a terminal part is stale.
tool_state_is_terminal :: proc(state: wire.Tool_State) -> bool {
    #partial switch _ in state {
    case wire.Tool_State_Completed, wire.Tool_State_Error, wire.Tool_State_Denied, wire.Tool_State_Canceled:
        return true
    }

    return false
}

// A waiting-permission state is still eligible for a decision when it has no decision
// recorded yet and carries options to decide among.
permission_state_is_awaiting :: proc(state: wire.Permission_State) -> bool {
    if _, has_decision := state.decision.?; has_decision {
        return false
    }

    _, has_options := state.options.?

    return has_options
}

// Checked cast from a wire ordinal to an `int` collection index.
to_index :: proc(v: u64) -> (int, bool) {
    if v > u64(max(int)) {
        return 0, false
    }

    return int(v), true
}

// --- borrow-returning views ---

// Borrow active draft metadata; ok is false when no draft is open.
replica_active_info :: proc(self: ^Session_Replica) -> (Active_Info, bool) {
    if self.active == nil {
        return {}, false
    }

    d := self.active

    return Active_Info {
            message_id = d.message_id,
            run_id = d.run_id,
            config_rev = d.config_rev,
            agent = d.agent,
            created_at_ms = d.created_at_ms,
            part_count = len(d.parts),
        },
        true
}

// A part's kind; carries no borrowed memory. ok is false if the part is absent.
replica_part_kind :: proc(self: ^Session_Replica, part_id: wire.Part_Id) -> (Part_Kind, bool) {
    part := part_at(self, part_id)
    if part == nil {
        return {}, false
    }

    return part.kind, true
}

// Borrow accumulated text/reasoning bytes; ok is false for an opaque redacted
// reasoning part, a tool, or an absent part.
// Invalidated by any later replica mutation.
replica_part_text :: proc(self: ^Session_Replica, part_id: wire.Part_Id) -> (string, bool) {
    part := part_at(self, part_id)
    if part == nil || (part.kind != .Text && part.kind != .Reasoning) {
        return "", false
    }

    return string(part.text.bytes[:]), true
}

// Borrow the complete active tool part, or nil for a non-tool or absent part.
// Invalidated by any later replica mutation that moves parts, replaces tool state, or
// ends the draft.
replica_tool_part :: proc(self: ^Session_Replica, part_id: wire.Part_Id) -> ^wire.Tool_Part {
    part := part_at(self, part_id)
    if part == nil || part.kind != .Tool {
        return nil
    }

    return &part.tool.tool
}

// Borrow the display output streamed so far for a tool part; ok is false for a non-tool or
// absent part. Invalidated by any later replica mutation, like `replica_tool_part`.
replica_tool_output :: proc(self: ^Session_Replica, part_id: wire.Part_Id) -> (string, bool) {
    part := part_at(self, part_id)
    if part == nil || part.kind != .Tool {
        return "", false
    }

    return string(part.tool.output[:]), true
}

// Borrow the tool call awaiting permission, materialized from the active draft's tool
// state. Invalidated by any later replica mutation, like `replica_tool_part`.
replica_pending_permission :: proc(self: ^Session_Replica) -> (Pending_Permission_View, bool) {
    if self.active == nil {
        return {}, false
    }

    for &part in self.active.parts {
        if part.kind != .Tool {
            continue
        }

        tool := &part.tool.tool

        if _, is_waiting := tool.state.(wire.Tool_State_Waiting_Permission); !is_waiting {
            continue
        }

        perm, has_perm := tool.permission_state.?
        if !has_perm || !permission_state_is_awaiting(perm) {
            continue
        }

        options, has_options := perm.options.?
        if !has_options {
            continue
        }

        return Pending_Permission_View {
                message_id = self.active.message_id,
                part_id = tool.id,
                tool_name = tool.name,
                arguments = tool.arguments,
                options = options,
                requested_at_ms = perm.requested_at_ms,
            },
            true
    }

    return {}, false
}

// Borrow a committed message by id; ok is false if absent. Slices borrow the message's
// arena, invalidated when that id changes or the replica mutates.
replica_committed_by_id :: proc(self: ^Session_Replica, id: wire.Message_Id) -> (wire.Message, bool) {
    for owned in self.messages {
        if wire.message_id(owned.message) == id {
            return owned.message, true
        }
    }

    return {}, false
}

// Borrow a config by revision; ok is false if absent. Strings borrow `configs_arena`.
replica_config :: proc(self: ^Session_Replica, config_rev: wire.Config_Rev) -> (wire.Run_Config, bool) {
    for cfg in self.configs {
        if cfg.config_rev == config_rev {
            return cfg, true
        }
    }

    return {}, false
}

// --- committed window / config / input folding ---

// Deep-copy, upsert by id keeping oldest-first order, seal, and dequeue committed user
// input. Transactional: on an allocation failure the prior window is intact and the
// candidate clone is freed.
replica_on_committed :: proc(
    self: ^Session_Replica,
    data: wire.Message_Committed_Data,
) -> (
    Apply_Result,
    Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    mid := wire.message_id(data.message)

    owned := owned_message_clone(data.message, self.allocator)

    inserted := false
    for &existing, i in self.messages {
        existing_id := wire.message_id(existing.message)

        // Same id: replace in place.
        if existing_id == mid {
            owned_message_destroy(&existing)
            self.messages[i] = owned
            inserted = true

            break
        }

        // First larger id: insert here to keep oldest-first order.
        if existing_id > mid {
            inject_at(&self.messages, i, owned)

            evict_oldest_if_full(self)
            inserted = true

            break
        }
    }

    // Newest: append at tail.
    if !inserted {
        append(&self.messages, owned)

        evict_oldest_if_full(self)
    }

    advance_finalized(self, mid)

    // Only a committed user message dequeues its accepted input; assistant and compaction
    // messages carry no `input_id`.
    if user, is_user := data.message.(wire.User_Message); is_user {
        for &queued, i in self.queued {
            if queued.input.input_id == user.input_id {
                owned_queued_input_destroy(&queued)
                ordered_remove(&self.queued, i)

                break
            }
        }
    }

    // Clear only the draft this commit finalizes.
    if self.active != nil && self.active.message_id == mid {
        drop_active(self)
    }

    return {kind = .Committed, message_id = mid}, .None
}

// Upsert an immutable config keyed by `config_rev`, cloning strings into `configs_arena`.
// A revision that reappears with different content is a protocol conflict.
replica_on_config_changed :: proc(
    self: ^Session_Replica,
    data: wire.Config_Changed_Data,
) -> (
    Apply_Result,
    Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    for existing in self.configs {
        if existing.config_rev == data.config.config_rev {
            // Odin compares strings by content.
            if existing.model != data.config.model || existing.reasoning != data.config.reasoning {
                return {}, .Config_Revision_Conflict
            }

            return {kind = .Ignored}, .None
        }
    }

    reserve(&self.configs, len(self.configs) + 1)

    a := mem.dynamic_arena_allocator(&self.configs_arena)
    cloned := wire.run_config_clone(data.config, a)
    append(&self.configs, cloned) // capacity reserved above

    return {kind = .Changed}, .None
}

// Drop committed messages at or above the cut. The draft is left to discard/resync.
replica_on_truncated :: proc(self: ^Session_Replica, data: wire.Transcript_Truncated_Data) -> Apply_Result {
    if self.session_id != data.session_id {
        return {kind = .Ignored}
    }

    changed := false
    for i := len(self.messages); i > 0; i -= 1 {
        idx := i - 1

        if wire.message_id(self.messages[idx].message) >= data.first_removed_id {
            owned_message_destroy(&self.messages[idx])
            ordered_remove(&self.messages, idx)
            changed = true
        }
    }

    return {kind = changed ? .Changed : .Ignored}
}

// Append a queued input, ignoring a duplicate `input_id`.
replica_on_input_queued :: proc(
    self: ^Session_Replica,
    data: wire.Input_Queued_Data,
) -> (
    Apply_Result,
    Replica_Error,
) {
    if self.session_id != data.session_id {
        return {kind = .Ignored}, .None
    }

    for queued in self.queued {
        if queued.input.input_id == data.input.input_id {
            return {kind = .Ignored}, .None
        }
    }

    owned := owned_queued_input_clone(data.input, self.allocator)

    append(&self.queued, owned)

    return {kind = .Changed}, .None
}

// Remove a queued input by id and reclaim its arena.
replica_on_input_canceled :: proc(self: ^Session_Replica, data: wire.Input_Canceled_Data) -> Apply_Result {
    if self.session_id != data.session_id {
        return {kind = .Ignored}
    }

    for &queued, i in self.queued {
        if queued.input.input_id == data.input_id {
            owned_queued_input_destroy(&queued)
            ordered_remove(&self.queued, i)

            return {kind = .Changed}
        }
    }

    return {kind = .Ignored}
}

// Clear a queued compaction when its matching run starts or terminates. Run ids are unique
// across turn and compaction runs, so unrelated run lifecycle events cannot clear it.
replica_clear_pending_compaction :: proc(self: ^Session_Replica, run_id: wire.Run_Id) -> Apply_Result {
    if pending, ok := self.pending_compaction.?; ok && pending == run_id {
        self.pending_compaction = nil
        self.last_cleared_compaction = run_id

        return {kind = .Changed}
    }

    return {kind = .Ignored}
}

// Evict the oldest committed message once the window exceeds the retained page, marking
// that older history exists.
evict_oldest_if_full :: proc(self: ^Session_Replica) {
    if len(self.messages) > MAX_RETAINED_MESSAGES {
        owned_message_destroy(&self.messages[0])
        ordered_remove(&self.messages, 0)
        self.has_more = true
    }
}

// --- sequence gating and dispatch ---

// Offer one session-scoped transcript/activity broadcast. Foreign-session and other-domain
// broadcasts (e.g. `session.removed`, `session.summary_changed`) are ignored before
// sequence gating. A gap leaves the replica unchanged and tells its controller to resync.
replica_apply_broadcast :: proc(
    self: ^Session_Replica,
    bc: wire.Notification,
) -> (
    res: Apply_Result,
    err: Replica_Error,
) {
    sid, ok := replica_domain_session_id(bc.params)
    if !ok || sid != self.session_id {
        return {kind = .Ignored}, .None
    }

    // Durable events gate on the per-session sequence; live events fold directly.
    if seq, has_seq := wire.broadcast_data_seq(bc.params).?; has_seq {
        if seq <= self.base_seq {
            return {kind = .Ignored}, .None // stale, already represented
        }

        if seq > self.base_seq + 1 {
            return {kind = .Gap}, .None // missed a durable event
        }

        result := apply_durable(self, bc) or_return

        self.base_seq = seq

        return result, .None
    }

    return apply_live(self, bc)
}

// Dispatch a contiguous durable broadcast to its state handler. Only the five durable-seq
// arms reach here (the caller gated on `broadcast_data_seq`). `Run_Done_Data` covers every
// run outcome (completed, canceled, or failed) and clears a pending compaction keyed by the
// terminal run unconditionally.
apply_durable :: proc(self: ^Session_Replica, bc: wire.Notification) -> (Apply_Result, Replica_Error) {
    #partial switch v in bc.params {
    case wire.Message_Committed_Data:
        return replica_on_committed(self, v)

    case wire.Config_Changed_Data:
        return replica_on_config_changed(self, v)

    case wire.Transcript_Truncated_Data:
        return replica_on_truncated(self, v), .None

    case wire.Run_Done_Data:
        return replica_clear_pending_compaction(self, v.run_id), .None

    case wire.Run_Started_Data:
        // Only a compaction run's start clears the queued compaction; a turn run just
        // advances the sequence.
        if v.kind == .Compaction {
            return replica_clear_pending_compaction(self, v.run_id), .None
        }

        return {kind = .Ignored}, .None
    }

    return {kind = .Ignored}, .None
}

// Dispatch a live broadcast to its lifecycle handler. `session.activity` replaces the
// pending-compaction slot in place (it carries no sequence) after its locators are checked
// against the replica's own draft.
apply_live :: proc(self: ^Session_Replica, bc: wire.Notification) -> (Apply_Result, Replica_Error) {
    #partial switch v in bc.params {
    case wire.Message_Started_Data:
        return replica_on_started(self, v)

    case wire.Message_Part_Added_Data:
        return replica_on_part_added(self, v)

    case wire.Message_Part_Delta_Data:
        return replica_on_part_delta(self, v)

    case wire.Tool_State_Changed_Data:
        return replica_on_tool_state_changed(self, v)

    case wire.Tool_Output_Delta_Data:
        return replica_on_tool_output_delta(self, v)

    case wire.Message_Discarded_Data:
        return replica_on_discarded(self, v), .None

    case wire.Input_Queued_Data:
        return replica_on_input_queued(self, v)

    case wire.Input_Canceled_Data:
        return replica_on_input_canceled(self, v), .None

    case wire.Session_Activity_Changed_Data:
        if activity_locators_diverge(self, v.activity.state) {
            return {kind = .Gap}, .None
        }

        incoming := v.activity.pending_compaction

        // A stale activity must not re-assert a compaction a durable `run.done` already
        // cleared; run ids are never reused, so this can only be that same cleared id.
        if pc, ok := incoming.?; ok {
            if cleared, has_cleared := self.last_cleared_compaction.?; has_cleared && pc == cleared {
                incoming = nil
            }
        }

        if self.pending_compaction == incoming {
            return {kind = .Ignored}, .None
        }

        self.pending_compaction = incoming

        return {kind = .Changed}, .None
    }

    return {kind = .Ignored}, .None
}

// Owning session id for a replica-domain broadcast; ok is false for foreign-domain events
// this replica never folds or buffers (`session.removed`, `session.summary_changed`, and
// non-session catalog broadcasts). Mirrors the Zig `applyBroadcast` domain switch, which
// is narrower than `wire.broadcast_data_session_id`.
replica_domain_session_id :: proc(data: wire.Broadcast_Data) -> (wire.Session_Id, bool) {
    #partial switch v in data {
    case wire.Message_Committed_Data:
        return v.session_id, true

    case wire.Config_Changed_Data:
        return v.session_id, true

    case wire.Transcript_Truncated_Data:
        return v.session_id, true

    case wire.Run_Started_Data:
        return v.session_id, true

    case wire.Run_Done_Data:
        return v.session_id, true

    case wire.Message_Started_Data:
        return v.session_id, true

    case wire.Message_Part_Added_Data:
        return v.session_id, true

    case wire.Message_Part_Delta_Data:
        return v.session_id, true

    case wire.Tool_State_Changed_Data:
        return v.session_id, true

    case wire.Tool_Output_Delta_Data:
        return v.session_id, true

    case wire.Message_Discarded_Data:
        return v.session_id, true

    case wire.Input_Queued_Data:
        return v.session_id, true

    case wire.Input_Canceled_Data:
        return v.session_id, true

    case wire.Session_Activity_Changed_Data:
        return v.session_id, true
    }

    return {}, false
}

// --- resync install ---

// Reconstruct a mid-flight draft from a resync snapshot so subsequent deltas resume at the
// right offset. Metadata comes from the draft message itself (`Active_Draft` is just
// `{message}`), and each part is copied into the draft arena. A part whose ordinal does not
// equal its index is a malformed snapshot. On any failure the draft is fully rolled back and
// nil is returned.
draft_from_snapshot :: proc(self: ^Session_Replica, src: wire.Active_Draft) -> (^Draft_Replica, Replica_Error) {
    msg := src.message

    d := new(Draft_Replica, self.allocator)

    mem.dynamic_arena_init(&d.arena, self.allocator, self.allocator)
    arena_alloc := mem.dynamic_arena_allocator(&d.arena)

    d.message_id = msg.id
    d.run_id = msg.run_id
    d.config_rev = msg.config_rev
    d.created_at_ms = msg.time.created_at_ms
    d.agent = strings.clone(msg.agent, arena_alloc)

    parts := make([dynamic]Active_Part, 0, len(msg.content), arena_alloc)

    d.parts = parts

    for part, index in msg.content {
        // Part ids are ordinals; a snapshot draft with holes is malformed.
        ord, ok := to_index(u64(wire.assistant_part_id(part)))
        if !ok || ord != index {
            draft_destroy(self.allocator, d)

            return nil, .Malformed_Snapshot
        }

        active, berr := active_part_from_wire(part, arena_alloc)
        if berr != .None {
            draft_destroy(self.allocator, d)

            return nil, berr
        }

        // Seed the offset baseline from output a running tool already streamed, so
        // post-resync deltas resume from the snapshot's byte length.
        if tool_part, is_tool := part.(wire.Tool_Part); is_tool {
            if running, is_running := tool_part.state.(wire.Tool_State_Running); is_running {
                if out, has_out := running.output.?; has_out {
                    append(&active.tool.output, out)
                }
            }
        }

        append(&d.parts, active)
    }

    return d, .None
}

// Install a validated resync cut transactionally. The owning controller drops session
// broadcasts while the request is in flight; the ordered response is the cut barrier, so
// no replay is needed. Build errors preserve prior state. Odin has no `errdefer`, so a
// single `committed`-guarded `defer` tears down every candidate before the commit.
replica_install_snapshot :: proc(self: ^Session_Replica, r: wire.Session_Resync_Result) -> Replica_Error {
    if wire.session_resync_result_validate(r) != .None {
        return .Malformed_Snapshot
    }

    if self.session_id != r.item.session.id {
        return .Session_Mismatch
    }

    if len(r.messages) > MAX_RETAINED_MESSAGES {
        return .Malformed_Snapshot
    }

    // --- Build candidates. Nothing below touches `self` until the commit. ---
    committed := false

    cand_messages := make([dynamic]Owned_Message, 0, len(r.messages), self.allocator)
    cand_queued := make([dynamic]Owned_Queued_Input, 0, len(r.queued), self.allocator)
    cand_configs := make([dynamic]wire.Run_Config, 0, len(r.configs), self.allocator)
    cand_cfg_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&cand_cfg_arena, self.allocator, self.allocator)
    cand_active: ^Draft_Replica = nil

    // The errdefer analogue: fires on every early return until `committed` is set.
    defer if !committed {
        for &m in cand_messages {
            owned_message_destroy(&m)
        }
        delete(cand_messages)

        for &q in cand_queued {
            owned_queued_input_destroy(&q)
        }
        delete(cand_queued)

        mem.dynamic_arena_destroy(&cand_cfg_arena)
        delete(cand_configs)

        if cand_active != nil {
            draft_destroy(self.allocator, cand_active)
        }
    }

    // The wire validator established ordering, uniqueness, boundaries, and references.
    for msg in r.messages {
        owned := owned_message_clone(msg, self.allocator)
        append(&cand_messages, owned) // capacity reserved by make
    }

    cfg_alloc := mem.dynamic_arena_allocator(&cand_cfg_arena)
    for cfg in r.configs {
        append(&cand_configs, wire.run_config_clone(cfg, cfg_alloc))
    }

    if src, has_active := r.active.?; has_active {
        draft := draft_from_snapshot(self, src) or_return

        cand_active = draft
    }

    for qi in r.queued {
        owned := owned_queued_input_clone(qi, self.allocator)
        append(&cand_queued, owned) // capacity reserved by make
    }

    // --- Commit: infallible from here. Free old owned state, move candidates in. ---
    replica_free_owned(self)
    self.messages = cand_messages
    self.queued = cand_queued
    self.configs = cand_configs
    self.configs_arena = cand_cfg_arena
    self.active = cand_active
    self.base_seq = r.base_seq
    self.has_more = r.has_more
    self.highest_finalized_id = r.highest_finalized_message_id
    self.pending_compaction = r.item.activity.pending_compaction
    self.last_cleared_compaction = nil
    committed = true

    return .None
}
