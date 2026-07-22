package client

import "core:mem"
import "core:strings"
import wire "src:wire"

// Largest committed window retained live; older messages fall off.
MAX_RETAINED_MESSAGES :: wire.LIMITS.max_page_size

// Resync-buffer caps; crossing either forces a fresh resync after install.
MAX_BUFFERED_EVENTS :: 1024
MAX_BUFFERED_BYTES :: 4 * 1024 * 1024

// Failure modes surfaced by the fallible replica procedures. `None` is success.
Replica_Error :: enum {
    None = 0,
    Out_Of_Memory,
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

    // A discontinuity started a resync.
    Gap,

    // Captured into the resync buffer for later replay.
    Buffered,
}

// Result of applying one broadcast. `message_id` is meaningful only for `.Discarded`
// and `.Committed`.
Apply_Result :: struct {
    kind:       Apply_Kind,
    message_id: wire.Message_Id,
}

// Result of installing a resync snapshot.
Install_Outcome :: enum {
    // Caught up; live again.
    Live,

    // A replay gap or buffer overflow needs another resync.
    Resync_Again,
}

// Kind of one active assistant part. Text and reasoning share the `Text_Buffer` payload.
Part_Kind :: enum {
    Text,
    Reasoning,
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
    kind: Part_Kind,
    text: Text_Buffer, // used for `.Text` and `.Reasoning`
    tool: Tool_Buffer, // used for `.Tool`; owned by the draft arena
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

// Broadcasts captured while a resync is in flight, replayed in arrival order.
Resync_Buffer :: struct {
    // Owns every cloned broadcast and the event list.
    arena:    mem.Dynamic_Arena,

    // Captured broadcasts, arrival order; backed by `arena`.
    events:   [dynamic]wire.Broadcast,

    // Running total of cloned broadcast bytes; the byte-cap backstop (no single "used"
    // field on a Dynamic_Arena).
    bytes:    int,

    // The prior buffer was discarded after crossing a cap.
    overflow: bool,
}

// The active-draft tool part awaiting permission; the view is materialized from it.
Permission_Locator :: struct {
    message_id: wire.Message_Id,
    part_id:    wire.Part_Id,
}

// Replica-local pending-permission view. The simplified wire no longer carries a pending
// permission in resync, so this is derived from the active draft's tool state. All
// borrowed fields point into the draft arena and die with the draft.
Pending_Permission_View :: struct {
    message_id:      wire.Message_Id,
    part_id:         wire.Part_Id,
    tool_name:       string,
    arguments:       string,
    options:         []wire.Permission_Option,
    requested_at_ms: u64,
}

// Borrowed active-draft metadata. `agent` points into the draft arena and is invalidated
// by any operation that ends or replaces the draft, or by `replica_deinit`.
Active_Info :: struct {
    message_id:    wire.Message_Id,
    run_id:        wire.Run_Id,
    config_rev:    wire.Config_Rev,
    agent:         string,
    created_at_ms: u64,
    part_count:    int,
}

// Owned state for one session. Ids are keys, never indices; `highest_finalized_id` is
// the seal boundary. `active` and `resync` are pointers (nil = none) because both are
// mutated in place; this diverges deliberately from the Zig inline optional/union.
Session_Replica :: struct {
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

    // Tool part awaiting permission; the view borrows from the draft.
    pending_permission:      Maybe(Permission_Locator),

    // Non-nil while buffering broadcasts during an in-flight resync; nil = live.
    resync:                  ^Resync_Buffer,
}

// --- construction / teardown ---

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
// inputs, plus their spines. Does NOT touch `resync` — a buffered replay outlives the
// install that calls this. Mirrors the teardown in the install commit step; keep the two
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

// Free all owned state, including any in-flight resync buffer, and zero the replica.
replica_deinit :: proc(self: ^Session_Replica) {
    replica_free_owned(self)

    if self.resync != nil {
        resync_buffer_destroy(self.allocator, self.resync)
        self.resync = nil
    }

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

// Destroy a resync buffer: free its arena, then the heap-allocated struct.
resync_buffer_destroy :: proc(allocator: mem.Allocator, buffer: ^Resync_Buffer) {
    mem.dynamic_arena_destroy(&buffer.arena)
    free(buffer, allocator)
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

    arena_alloc := mem.dynamic_arena_allocator(&draft.arena)
    part := active_part_from_wire(data.part, arena_alloc) or_return

    if _, aerr := append(&draft.parts, part); aerr != nil {
        return {}, .Out_Of_Memory
    }

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

    // Only text and reasoning parts carry a byte buffer; a delta targeting a tool is a gap.
    if part.kind == .Tool {
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

    _, aerr := append(&part.text.bytes, data.delta)
    if aerr != nil {
        return {}, .Out_Of_Memory
    }

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

    _, aerr := append(&part.tool.output, data.delta)
    if aerr != nil {
        return {}, .Out_Of_Memory
    }

    return {kind = .Changed}, .None
}

// Replace the full live state of an existing tool part. This is the sole source of
// `pending_permission`: it sets the locator when a tool part enters
// `Tool_State_Waiting_Permission` and clears it when the tracked part leaves.
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

    // Validate the transition before mutating state.
    now_waiting := false

    if waiting, is_waiting := data.state.(wire.Tool_State_Waiting_Permission); is_waiting {
        // A resolution must not leave the state in waiting_permission.
        if !permission_state_is_awaiting(waiting.permission_state) {
            return {kind = .Gap}, .None
        }

        if pending, has_pending := self.pending_permission.?; has_pending {
            if pending.message_id != data.message_id || pending.part_id != data.part_id {
                return {kind = .Gap}, .None
            }
        }

        now_waiting = true
    }

    // Previous tool state is owned by the draft arena; replaced in place. The superseded
    // clone is not freed until draft teardown (a Dynamic_Arena has no per-object free).
    arena_alloc := mem.dynamic_arena_allocator(&draft.arena)
    part.tool.tool.state = wire.tool_state_clone(data.state, arena_alloc)

    if now_waiting {
        self.pending_permission = Permission_Locator {
            message_id = data.message_id,
            part_id    = data.part_id,
        }
    } else if pending, has_pending := self.pending_permission.?; has_pending {
        // Leaving waiting on the tracked part clears it.
        if pending.message_id == data.message_id && pending.part_id == data.part_id {
            self.pending_permission = nil
        }
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
        clear_pending_permission_for_message(self, data.message_id)
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
    d, err := new(Draft_Replica, self.allocator)
    if err != nil {
        return nil, .Out_Of_Memory
    }

    mem.dynamic_arena_init(&d.arena, self.allocator, self.allocator)
    arena_alloc := mem.dynamic_arena_allocator(&d.arena)

    parts, perr := make([dynamic]Active_Part, 0, arena_alloc)
    if perr != nil {
        mem.dynamic_arena_destroy(&d.arena)
        free(d, self.allocator)

        return nil, .Out_Of_Memory
    }

    d.message_id = data.message_id
    d.run_id = data.run_id
    d.config_rev = data.config_rev
    d.created_at_ms = data.created_at_ms
    d.agent = strings.clone(data.agent, arena_alloc)
    d.parts = parts

    return d, .None
}

// Build a text/reasoning byte buffer in the draft arena, folding the initial bytes. A
// mid-build allocation failure surfaces `.Out_Of_Memory` so a truncated buffer never
// escapes as a folded part.
text_buffer_build :: proc(id: wire.Part_Id, text: string, allocator: mem.Allocator) -> (Text_Buffer, Replica_Error) {
    bytes, err := make([dynamic]u8, 0, allocator)
    if err != nil {
        return {}, .Out_Of_Memory
    }

    if _, aerr := append(&bytes, text); aerr != nil {
        return {}, .Out_Of_Memory
    }

    return Text_Buffer{id = id, bytes = bytes}, .None
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
        buf := text_buffer_build(v.id, v.text, allocator) or_return

        return Active_Part{kind = .Text, text = buf}, .None

    case wire.Reasoning_Part:
        buf := text_buffer_build(v.id, v.text, allocator) or_return

        return Active_Part{kind = .Reasoning, text = buf}, .None

    case wire.Tool_Part:
        // `wire.tool_part_clone` cannot signal OOM, and the output buffer only records its
        // arena allocator (no allocation) here, so this arm never fails mid-build.
        buf: Tool_Buffer
        buf.tool = wire.tool_part_clone(v, allocator)
        buf.output.allocator = allocator

        return Active_Part{kind = .Tool, tool = buf}, .None
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

// Clear a pending permission anchored in `message_id`.
clear_pending_permission_for_message :: proc(self: ^Session_Replica, message_id: wire.Message_Id) {
    if pending, ok := self.pending_permission.?; ok && pending.message_id == message_id {
        self.pending_permission = nil
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

// Borrow accumulated text/reasoning bytes; ok is false for a tool or absent part.
// Invalidated by any later replica mutation.
replica_part_text :: proc(self: ^Session_Replica, part_id: wire.Part_Id) -> (string, bool) {
    part := part_at(self, part_id)
    if part == nil || part.kind == .Tool {
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
    pending, ok := self.pending_permission.?
    if !ok {
        return {}, false
    }

    tool := replica_tool_part(self, pending.part_id)
    if tool == nil {
        return {}, false
    }

    waiting, is_waiting := tool.state.(wire.Tool_State_Waiting_Permission)
    if !is_waiting {
        return {}, false
    }

    options, has_options := waiting.permission_state.options.?
    if !has_options {
        return {}, false
    }

    return Pending_Permission_View {
            message_id = pending.message_id,
            part_id = pending.part_id,
            tool_name = tool.name,
            arguments = tool.arguments,
            options = options,
            requested_at_ms = waiting.permission_state.requested_at_ms,
        },
        true
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
            if _, ierr := inject_at(&self.messages, i, owned); ierr != nil {
                owned_message_destroy(&owned)

                return {}, .Out_Of_Memory
            }

            evict_oldest_if_full(self)
            inserted = true

            break
        }
    }

    // Newest: append at tail.
    if !inserted {
        if _, aerr := append(&self.messages, owned); aerr != nil {
            owned_message_destroy(&owned)

            return {}, .Out_Of_Memory
        }

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

    clear_pending_permission_for_message(self, mid)

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

    // Grow before cloning so an OOM on growth can't leak unreachable bytes into the
    // shared configs_arena.
    if rerr := reserve(&self.configs, len(self.configs) + 1); rerr != nil {
        return {}, .Out_Of_Memory
    }

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

    if _, aerr := append(&self.queued, owned); aerr != nil {
        owned_queued_input_destroy(&owned)

        return {}, .Out_Of_Memory
    }

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
// broadcasts (e.g. `session.removed`, `session.summary_changed`) are ignored before any
// gating or buffering, so they can neither advance the sequence nor enter the buffer.
replica_apply_broadcast :: proc(
    self: ^Session_Replica,
    bc: wire.Broadcast,
) -> (
    res: Apply_Result,
    err: Replica_Error,
) {
    sid, ok := replica_domain_session_id(bc.data)
    if !ok || sid != self.session_id {
        return {kind = .Ignored}, .None
    }

    // Buffer everything while a resync is in flight; replay happens after install.
    if self.resync != nil {
        return buffer_event(self, bc)
    }

    // Durable events gate on the per-session sequence; live events fold directly.
    if seq, has_seq := wire.broadcast_data_seq(bc.data).?; has_seq {
        if seq <= self.base_seq {
            return {kind = .Ignored}, .None // stale, already represented
        }

        if seq > self.base_seq + 1 {
            return gap_resync(self, bc) // missed a durable event
        }

        result := apply_durable(self, bc) or_return

        self.base_seq = seq

        return result, .None
    }

    result := apply_live(self, bc) or_return

    if result.kind == .Gap {
        return gap_resync(self, bc)
    }

    return result, .None
}

// Dispatch a contiguous durable broadcast to its state handler. Only the five durable-seq
// arms reach here (the caller gated on `broadcast_data_seq`). The former
// `run.done`/`run.canceled`/`run.failed` broadcasts are now the single `Run_Done_Data`
// arm, which clears a pending compaction keyed by the terminal run unconditionally.
apply_durable :: proc(self: ^Session_Replica, bc: wire.Broadcast) -> (Apply_Result, Replica_Error) {
    #partial switch v in bc.data {
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
// pending-compaction slot in place (it carries no sequence).
apply_live :: proc(self: ^Session_Replica, bc: wire.Broadcast) -> (Apply_Result, Replica_Error) {
    #partial switch v in bc.data {
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

// --- resync buffering ---

// Enter the resyncing state; a second call coalesces into the existing buffer. Diverges
// from the Zig inline union: the buffer is heap-allocated and `self.resync` points at it
// (nil = live), so mutable buffering has a stable pointer.
replica_begin_resync :: proc(self: ^Session_Replica) -> Replica_Error {
    if self.resync != nil {
        return .None
    }

    buf, err := new(Resync_Buffer, self.allocator)
    if err != nil {
        return .Out_Of_Memory
    }

    mem.dynamic_arena_init(&buf.arena, self.allocator, self.allocator)
    buf.events.allocator = mem.dynamic_arena_allocator(&buf.arena)
    self.resync = buf

    return .None
}

// Discard any buffered events and open a fresh resync buffer. A new connection generation
// must not replay a dead connection's buffered events, so unlike `replica_begin_resync`
// this never coalesces into an existing buffer.
replica_restart_resync :: proc(self: ^Session_Replica) -> Replica_Error {
    if self.resync != nil {
        resync_buffer_destroy(self.allocator, self.resync)
        self.resync = nil
    }

    return replica_begin_resync(self)
}

// Start a resync and capture the event that revealed the gap.
gap_resync :: proc(self: ^Session_Replica, bc: wire.Broadcast) -> (res: Apply_Result, err: Replica_Error) {
    replica_begin_resync(self) or_return
    _ = buffer_event(self, bc) or_return

    return {kind = .Gap}, .None
}

// Capture a broadcast into the resync buffer, honoring the event-count and byte caps.
// Crossing either cap drops the whole prefix and keeps buffering into a fresh empty arena
// with `overflow` set, so the eventual install forces another resync.
buffer_event :: proc(self: ^Session_Replica, bc: wire.Broadcast) -> (Apply_Result, Replica_Error) {
    buf := self.resync

    if buf.overflow {
        return {kind = .Buffered}, .None
    }

    // Crossing either cap before adding this event discards the accumulated prefix.
    if len(buf.events) >= MAX_BUFFERED_EVENTS || buf.bytes > MAX_BUFFERED_BYTES {
        resync_buffer_reset_overflow(self, buf)

        return {kind = .Buffered}, .None
    }

    arena_alloc := mem.dynamic_arena_allocator(&buf.arena)
    cloned := wire.broadcast_clone(bc, arena_alloc)

    if _, aerr := append(&buf.events, cloned); aerr != nil {
        return {}, .Out_Of_Memory
    }

    // `Dynamic_Arena` exposes no bytes-used field, so track the buffered payload size by
    // its serialized length.
    buf.bytes += broadcast_size_estimate(bc)

    // A single oversized event trips the byte cap here rather than on the next call.
    if buf.bytes > MAX_BUFFERED_BYTES {
        resync_buffer_reset_overflow(self, buf)
    }

    return {kind = .Buffered}, .None
}

// Discard the buffer's arena and events, then keep it usable and flagged overflowed so
// later events buffer cheaply into a fresh empty arena until install.
resync_buffer_reset_overflow :: proc(self: ^Session_Replica, buf: ^Resync_Buffer) {
    mem.dynamic_arena_destroy(&buf.arena)
    mem.dynamic_arena_init(&buf.arena, self.allocator, self.allocator)
    buf.events = {}
    buf.events.allocator = mem.dynamic_arena_allocator(&buf.arena)
    buf.bytes = 0
    buf.overflow = true
}

// Serialized byte size of a broadcast, used as the resync byte-cap measure.
broadcast_size_estimate :: proc(bc: wire.Broadcast) -> int {
    e: wire.Emitter
    wire.emitter_init(&e, context.allocator)
    defer wire.emitter_destroy(&e)
    wire.broadcast_emit(&e, bc)

    return len(wire.to_string(&e))
}

// --- resync install and replay ---

// Reconstruct a mid-flight draft from a resync snapshot so subsequent deltas resume at the
// right offset. Metadata comes from the draft message itself (the simplified wire's
// `Active_Draft` is just `{message}`), and each part is copied into the draft arena. A part
// whose ordinal does not equal its index is a malformed snapshot. On any failure the draft
// is fully rolled back and nil is returned.
draft_from_snapshot :: proc(self: ^Session_Replica, src: wire.Active_Draft) -> (^Draft_Replica, Replica_Error) {
    msg := src.message

    d, err := new(Draft_Replica, self.allocator)
    if err != nil {
        return nil, .Out_Of_Memory
    }

    mem.dynamic_arena_init(&d.arena, self.allocator, self.allocator)
    arena_alloc := mem.dynamic_arena_allocator(&d.arena)

    d.message_id = msg.id
    d.run_id = msg.run_id
    d.config_rev = msg.config_rev
    d.created_at_ms = msg.time.created_at_ms
    d.agent = strings.clone(msg.agent, arena_alloc)

    parts, perr := make([dynamic]Active_Part, 0, len(msg.content), arena_alloc)
    if perr != nil {
        draft_destroy(self.allocator, d)

        return nil, .Out_Of_Memory
    }

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
                    if _, aerr := append(&active.tool.output, out); aerr != nil {
                        draft_destroy(self.allocator, d)

                        return nil, .Out_Of_Memory
                    }
                }
            }
        }

        if _, aerr := append(&d.parts, active); aerr != nil {
            draft_destroy(self.allocator, d)

            return nil, .Out_Of_Memory
        }
    }

    return d, .None
}

// Recompute the pending-permission locator from a freshly installed draft. The simplified
// wire no longer carries a pending permission in the resync snapshot, so it is derived from
// the draft's own tool state: the first tool part in `Tool_State_Waiting_Permission` with
// options present.
derive_pending_permission :: proc(active: ^Draft_Replica) -> Maybe(Permission_Locator) {
    if active == nil {
        return nil
    }

    for &part in active.parts {
        if part.kind != .Tool {
            continue
        }

        waiting, is_waiting := part.tool.tool.state.(wire.Tool_State_Waiting_Permission)
        if !is_waiting {
            continue
        }

        if !permission_state_is_awaiting(waiting.permission_state) {
            continue
        }

        return Permission_Locator{message_id = active.message_id, part_id = part.tool.tool.id}
    }

    return nil
}

// Install a resync snapshot transactionally, then replay any buffered broadcasts. Build
// errors preserve prior state; a replay gap or overflow keeps the installed snapshot and
// requests another resync. Odin has no `errdefer`, so a single `committed`-guarded `defer`
// tears down every candidate on any early return before the commit.
replica_install_snapshot :: proc(
    self: ^Session_Replica,
    r: wire.Resync_Result,
) -> (
    outcome: Install_Outcome,
    err: Replica_Error,
) {
    // The wire validator is stronger than the replica's inline checks (activity/queued and
    // activity/waiting-tool cross-checks); its failure is a malformed snapshot.
    if wire.resync_result_validate(r) != .None {
        return .Live, .Malformed_Snapshot
    }

    if self.session_id != r.item.session.id {
        return .Live, .Session_Mismatch
    }

    if len(r.messages) > MAX_RETAINED_MESSAGES {
        return .Live, .Malformed_Snapshot
    }

    // --- Build candidates. Nothing below touches `self` until the commit. ---
    committed := false

    cand_messages, e_m := make([dynamic]Owned_Message, 0, len(r.messages), self.allocator)
    cand_queued, e_q := make([dynamic]Owned_Queued_Input, 0, len(r.queued), self.allocator)
    cand_configs, e_c := make([dynamic]wire.Run_Config, 0, len(r.configs), self.allocator)
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

    if e_m != nil || e_q != nil || e_c != nil {
        return .Live, .Out_Of_Memory
    }

    // Messages: clone each, enforcing oldest-first, unique ids, all <= highest_finalized.
    prev_id: Maybe(wire.Message_Id)
    for msg in r.messages {
        mid := wire.message_id(msg)

        if prev, ok := prev_id.?; ok && mid <= prev {
            return .Live, .Malformed_Snapshot
        }

        if highest, ok := r.highest_finalized_message_id.?; !ok || mid > highest {
            return .Live, .Malformed_Snapshot
        }

        prev_id = mid

        owned := owned_message_clone(msg, self.allocator)
        append(&cand_messages, owned) // capacity reserved by make
    }

    // Configs: clone into the candidate arena, rejecting duplicate config_rev.
    cfg_alloc := mem.dynamic_arena_allocator(&cand_cfg_arena)
    for cfg in r.configs {
        for existing in cand_configs {
            if existing.config_rev == cfg.config_rev {
                return .Live, .Malformed_Snapshot
            }
        }

        append(&cand_configs, wire.run_config_clone(cfg, cfg_alloc))
    }

    // Referential integrity: every assistant message's config_rev exists.
    for msg in r.messages {
        if assistant, is_assistant := msg.(wire.Assistant_Message); is_assistant {
            if !config_rev_present(cand_configs[:], assistant.config_rev) {
                return .Live, .Malformed_Snapshot
            }
        }
    }

    // Active draft: id above highest_finalized, config_rev exists, then reconstruct it.
    if src, has_active := r.active.?; has_active {
        if highest, ok := r.highest_finalized_message_id.?; ok && src.message.id <= highest {
            return .Live, .Malformed_Snapshot
        }

        if !config_rev_present(cand_configs[:], src.message.config_rev) {
            return .Live, .Malformed_Snapshot
        }

        draft := draft_from_snapshot(self, src) or_return

        cand_active = draft
    }

    // Queued inputs: clone each, rejecting duplicate input_id.
    for qi in r.queued {
        for existing in cand_queued {
            if existing.input.input_id == qi.input_id {
                return .Live, .Malformed_Snapshot
            }
        }

        owned := owned_queued_input_clone(qi, self.allocator)
        append(&cand_queued, owned) // capacity reserved by make
    }

    // --- Commit: infallible from here. Free old owned state, move candidates in. ---
    replica_free_owned(self) // teardown mirroring deinit MINUS self.resync (replay needs it)
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
    self.pending_permission = derive_pending_permission(cand_active)
    committed = true

    return replica_replay_buffer(self)
}

// Detach and replay the resync buffer once, in arrival order. An overflowed buffer or a
// fresh gap during replay yields `.Resync_Again` and leaves the replica resyncing again.
replica_replay_buffer :: proc(self: ^Session_Replica) -> (Install_Outcome, Replica_Error) {
    if self.resync == nil {
        return .Live, .None
    }

    buf := self.resync
    self.resync = nil // detach so replay does not re-buffer into itself

    if buf.overflow {
        resync_buffer_destroy(self.allocator, buf)

        // Re-enter resyncing for the caller; an OOM here must surface rather than leave a
        // silent live/resyncing inconsistency.
        if err := replica_begin_resync(self); err != .None {
            return .Resync_Again, err
        }

        return .Resync_Again, .None
    }

    outcome := Install_Outcome.Live
    for ev in buf.events {
        result, err := replica_apply_broadcast(self, ev)
        if err != .None {
            // Mirror the Zig errdefer: re-enter resyncing, then propagate the original
            // failure (a begin_resync OOM is subsumed by the error we already return).
            resync_buffer_destroy(self.allocator, buf)
            _ = replica_begin_resync(self)

            return .Resync_Again, err
        }

        // A fresh gap re-entered resyncing and captured `ev`; the next resync supersedes
        // the rest of this buffer.
        if result.kind == .Gap {
            outcome = .Resync_Again

            break
        }
    }

    resync_buffer_destroy(self.allocator, buf)

    return outcome, .None
}

// True if `config_rev` is present in the candidate config set.
config_rev_present :: proc(configs: []wire.Run_Config, config_rev: wire.Config_Rev) -> bool {
    for cfg in configs {
        if cfg.config_rev == config_rev {
            return true
        }
    }

    return false
}
