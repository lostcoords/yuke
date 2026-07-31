package wire

import "core:strings"

// Request-time system prompt override; the default arm means the field was omitted.
System_Prompt_Default :: struct {}

// Field was explicitly `null`.
System_Prompt_None :: struct {}

// @unbounded
// Field carried an explicit value.
System_Prompt_Set :: struct {
    // @unbounded
    value: string,
}

// Request-time system prompt override. `default` means the field was omitted.
System_Prompt_Override :: union {
    System_Prompt_Default,
    System_Prompt_None,
    System_Prompt_Set,
}

// Deep-copy into `allocator`. Only `set` owns a slice.
system_prompt_override_clone :: proc(
    self: System_Prompt_Override,
    allocator := context.allocator,
) -> System_Prompt_Override {
    #partial switch v in self {
    case System_Prompt_Set:
        return System_Prompt_Set{value = strings.clone(v.value, allocator)}
    }

    return self
}

// Request-time max-rounds override; the default arm means the field was omitted.
Max_Rounds_Default :: struct {}

// Field was explicitly `null`.
Max_Rounds_Unlimited :: struct {}

// Field carried an explicit value.
Max_Rounds_Set :: struct {
    value: u64,
}

// Request-time max-rounds override. `default` means the field was omitted.
Max_Rounds_Override :: union {
    Max_Rounds_Default,
    Max_Rounds_Unlimited,
    Max_Rounds_Set,
}

// Deep-copy into `allocator`. All arms are bit-copyable.
max_rounds_override_clone :: proc(self: Max_Rounds_Override, allocator := context.allocator) -> Max_Rounds_Override {
    return self
}

// Write a system-prompt override as its resolved JSON value.
system_prompt_override_emit :: proc(e: ^Emitter, self: System_Prompt_Override) {
    switch v in self {
    case System_Prompt_None:
        val_null(e)

    case System_Prompt_Set:
        val_string(e, v.value)

    case System_Prompt_Default:
    // The default arm is never written; the caller skips it.
    }
}

// Write a max-rounds override as its resolved JSON value.
max_rounds_override_emit :: proc(e: ^Emitter, self: Max_Rounds_Override) {
    switch v in self {
    case Max_Rounds_Unlimited:
        val_null(e)

    case Max_Rounds_Set:
        val_u64(e, v.value)

    case Max_Rounds_Default:
    // The default arm is never written; the caller skips it.
    }
}

// session.create input. Non-owning.
Create_Session :: struct {
    // @unbounded
    // Filesystem path; omitted resolves to the home directory.
    workspace_path: Maybe(string),

    // @unbounded
    // Profile name to resolve config from.
    profile:        Maybe(string),

    // @unbounded
    // Model id override.
    model:          Maybe(string),

    // @unbounded
    // Reasoning level override.
    reasoning:      Maybe(string),

    // @tristate
    // @unbounded
    // Omitted = resolve from config. Explicit null = force no system prompt.
    system_prompt:  System_Prompt_Override,

    // Permission mode override.
    permission:     Maybe(Permission_Mode),

    // @tristate
    // Round-cap override.
    max_rounds:     Max_Rounds_Override,
}

// Write fields; omitted overrides are skipped.
create_session_emit :: proc(e: ^Emitter, self: Create_Session) {
    object_begin(e)
    field_string_opt(e, "workspace_path", self.workspace_path)
    field_string_opt(e, "profile", self.profile)
    field_string_opt(e, "model", self.model)
    field_string_opt(e, "reasoning", self.reasoning)
    _, sp_default := self.system_prompt.(System_Prompt_Default)

    if self.system_prompt != nil && !sp_default {
        key(e, "system_prompt")
        system_prompt_override_emit(e, self.system_prompt)
    }

    if mode, ok := self.permission.?; ok {
        field_string(e, "permission", permission_mode_to_wire(mode))
    }

    _, mr_default := self.max_rounds.(Max_Rounds_Default)

    if self.max_rounds != nil && !mr_default {
        key(e, "max_rounds")
        max_rounds_override_emit(e, self.max_rounds)
    }

    object_end(e)
}

// Verify annotated field bounds.
// Kept for consistency.
create_session_validate :: proc(self: Create_Session) -> Validation_Error {
    // Create_Session's request fields carry no bounds
    // (`workspace_path`/`system_prompt` are @unbounded; the rest are unmarked).
    return .None
}

// Deep-copy into `allocator`.
create_session_clone :: proc(self: Create_Session, allocator := context.allocator) -> Create_Session {
    out: Create_Session

    if p, ok := self.workspace_path.?; ok {
        out.workspace_path = strings.clone(p, allocator)
    }

    if p, ok := self.profile.?; ok {
        out.profile = strings.clone(p, allocator)
    }

    if p, ok := self.model.?; ok {
        out.model = strings.clone(p, allocator)
    }

    if p, ok := self.reasoning.?; ok {
        out.reasoning = strings.clone(p, allocator)
    }

    out.system_prompt = system_prompt_override_clone(self.system_prompt, allocator)
    out.permission = self.permission
    out.max_rounds = max_rounds_override_clone(self.max_rounds, allocator)

    return out
}

// Missing field means no change. The system prompt is snapshotted at creation
// and is not patchable. Non-owning.
Session_Patch :: struct {
    // @bounded 128
    // New model id.
    model:      Maybe(string),

    // @bounded 32
    // New reasoning level.
    reasoning:  Maybe(string),

    // New permission mode.
    permission: Maybe(Permission_Mode),

    // @tristate
    // New round cap.
    max_rounds: Max_Rounds_Override,
}

// Write only fields present in the patch.
session_patch_emit :: proc(e: ^Emitter, self: Session_Patch) {
    object_begin(e)
    field_string_opt(e, "model", self.model)
    field_string_opt(e, "reasoning", self.reasoning)

    if mode, ok := self.permission.?; ok {
        field_string(e, "permission", permission_mode_to_wire(mode))
    }

    _, mr_default := self.max_rounds.(Max_Rounds_Default)

    if self.max_rounds != nil && !mr_default {
        key(e, "max_rounds")
        max_rounds_override_emit(e, self.max_rounds)
    }

    object_end(e)
}

// Verify annotated field bounds.
session_patch_validate :: proc(self: Session_Patch) -> Validation_Error {
    if model, ok := self.model.?; ok {
        enforce_bounded(128, model) or_return
    }

    if reasoning, ok := self.reasoning.?; ok {
        enforce_bounded(32, reasoning) or_return
    }

    return .None
}

// session.fork input.
Session_Fork_Params :: struct {
    // Session to fork.
    session_id:        Session_Id,

    // Fork up to (exclusive); omit to fork the full transcript.
    before_message_id: Maybe(Message_Id),
}

// Write session.fork params.
session_fork_params_emit :: proc(e: ^Emitter, self: Session_Fork_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))

    if bid, ok := self.before_message_id.?; ok {
        field_u64(e, "before_message_id", u64(bid))
    }

    object_end(e)
}

// session.compact input.
Session_Compact_Params :: struct {
    // Session to compact.
    session_id: Session_Id,
}

// Write session.compact params.
session_compact_params_emit :: proc(e: ^Emitter, self: Session_Compact_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    object_end(e)
}

// Whether compaction started immediately or was queued.
Compact_Status :: enum {
    Started,
    Queued,
}

// Compact_Status <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
compact_status_wire := [Compact_Status]string {
    .Started = "started",
    .Queued  = "queued",
}

// Wire string for a compaction status.
compact_status_to_wire :: proc(s: Compact_Status) -> string {
    return compact_status_wire[s]
}

// Compaction status for a wire string; ok is false for an unknown status.
compact_status_from_wire :: proc(s: string) -> (Compact_Status, bool) {
    return enum_from_wire(compact_status_wire, s)
}

// session.compact result.
Session_Compact_Result :: struct {
    // Whether compaction started or was queued.
    status: Compact_Status,

    // Id of the compaction run.
    run_id: Run_Id,
}

// Write fields as JSON.
session_compact_result_emit :: proc(e: ^Emitter, self: Session_Compact_Result) {
    object_begin(e)
    field_string(e, "status", compact_status_to_wire(self.status))
    field_u64(e, "run_id", u64(self.run_id))
    object_end(e)
}

// session.rewind input.
Session_Rewind_Params :: struct {
    // Session to rewind.
    session_id:        Session_Id,

    // Rewind up to (exclusive).
    before_message_id: Message_Id,
}

// Write session.rewind params.
session_rewind_params_emit :: proc(e: ^Emitter, self: Session_Rewind_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "before_message_id", u64(self.before_message_id))
    object_end(e)
}

// Permission policy for future tool calls.
Permission_Mode :: enum {
    // Ask before sensitive actions.
    Strict,

    // Use daemon defaults.
    Normal,

    // Allow without prompting.
    Yolo,
}

// Permission_Mode <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
permission_mode_wire := [Permission_Mode]string {
    .Strict = "strict",
    .Normal = "normal",
    .Yolo   = "yolo",
}

// Wire string for a permission mode.
permission_mode_to_wire :: proc(m: Permission_Mode) -> string {
    return permission_mode_wire[m]
}

// Permission mode for a wire string; ok is false for an unknown mode.
permission_mode_from_wire :: proc(s: string) -> (Permission_Mode, bool) {
    return enum_from_wire(permission_mode_wire, s)
}

// User-created root session.
Session_Origin_Root :: struct {}

// Child of another session.
Session_Origin_Child :: struct {
    // Parent session id.
    parent_id:         Session_Id,

    // Message in the parent's transcript carrying the spawning tool part.
    parent_message_id: Message_Id,

    // Tool part within that message that spawned this session; together with
    // `parent_message_id` stays correct when one message emits multiple spawn calls.
    parent_part_id:    Part_Id,
}

// Fork of another session.
Session_Origin_Fork :: struct {
    // Source session id.
    source_id: Session_Id,
}

// Created by a cron job.
Session_Origin_Cron :: struct {
    // Owning cron job id.
    job_id: Job_Id,
}

// How a session was created.
Session_Origin :: union {
    Session_Origin_Root,
    Session_Origin_Child,
    Session_Origin_Fork,
    Session_Origin_Cron,
}

// Write internal-tagged JSON with `type` first.
session_origin_emit :: proc(e: ^Emitter, self: Session_Origin) {
    object_begin(e)

    switch v in self {
    case Session_Origin_Root:
        field_string(e, "type", "root")

    case Session_Origin_Child:
        field_string(e, "type", "child")
        field_id(e, "parent_id", ([16]u8)(v.parent_id))
        field_u64(e, "parent_message_id", u64(v.parent_message_id))
        field_u64(e, "parent_part_id", u64(v.parent_part_id))

    case Session_Origin_Fork:
        field_string(e, "type", "fork")
        field_id(e, "source_id", ([16]u8)(v.source_id))

    case Session_Origin_Cron:
        field_string(e, "type", "cron")
        field_id(e, "job_id", ([16]u8)(v.job_id))
    }

    object_end(e)
}

// Verify annotated field bounds.
session_origin_validate :: proc(self: Session_Origin) -> Validation_Error {
    switch v in self {
    case Session_Origin_Root:
        return .None

    case Session_Origin_Child:
        return enforce_id(([16]u8)(v.parent_id))

    case Session_Origin_Fork:
        return enforce_id(([16]u8)(v.source_id))

    case Session_Origin_Cron:
        return enforce_id(([16]u8)(v.job_id))
    }

    return .None
}

// Deep-copy into `allocator`. All arms carry only fixed-size ids.
session_origin_clone :: proc(self: Session_Origin, allocator := context.allocator) -> Session_Origin {
    return self
}

// Daemon-owned session summary.
Session :: struct {
    // @fixed 16
    // Session id.
    id:            Session_Id,

    // @fixed 16
    // Owning workspace id.
    workspace_id:  Workspace_Id,

    // @bounded 64
    // Profile name.
    profile:       string,

    // @bounded 128
    // Future-run model id.
    model:         string,

    // @bounded 32
    // Future-run reasoning level.
    reasoning:     string,

    // Future-run config revision.
    config_rev:    Config_Rev,

    // Live permission mode.
    permission:    Permission_Mode,

    // @required-nullable
    // Live round cap; null means unlimited.
    max_rounds:    Maybe(u64),

    // @bounded 256
    // Display title.
    title:         string,

    // Committed transcript message count.
    message_count: u64,

    // Last update epoch ms.
    updated_at_ms: u64,

    // @required-nullable
    // Client that created the session; null for daemon-created child/cron sessions.
    created_by:    Maybe(Client),

    // Session provenance.
    origin:        Session_Origin,

    // @bounded 64
    // Agent name, when known; omitted if unassigned. Lets a client listing children
    // name the agent without fetching a transcript.
    agent:         Maybe(string),
}

// Write a Session object. `created_by` and `max_rounds` are always present, null when absent;
// `agent` is omitted when absent.
session_emit :: proc(e: ^Emitter, self: Session) {
    object_begin(e)
    field_id(e, "id", ([16]u8)(self.id))
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    field_string(e, "profile", self.profile)
    field_string(e, "model", self.model)
    field_string(e, "reasoning", self.reasoning)
    field_u64(e, "config_rev", u64(self.config_rev))
    field_string(e, "permission", permission_mode_to_wire(self.permission))
    field_required_null_u64(e, "max_rounds", self.max_rounds)
    field_string(e, "title", self.title)
    field_u64(e, "message_count", self.message_count)
    field_u64(e, "updated_at_ms", self.updated_at_ms)
    key(e, "created_by")

    if cb, ok := self.created_by.?; ok {
        client_emit(e, cb)
    } else {
        val_null(e)
    }

    key(e, "origin")
    session_origin_emit(e, self.origin)
    field_string_opt(e, "agent", self.agent)
    object_end(e)
}

// Verify annotated field bounds.
session_validate :: proc(self: Session) -> Validation_Error {
    enforce_id(([16]u8)(self.id)) or_return
    enforce_id(([16]u8)(self.workspace_id)) or_return
    enforce_bounded(64, self.profile) or_return
    enforce_bounded(128, self.model) or_return
    enforce_bounded(32, self.reasoning) or_return
    enforce_bounded(256, self.title) or_return

    if agent, ok := self.agent.?; ok {
        enforce_bounded(64, agent) or_return
    }

    if cb, ok := self.created_by.?; ok {
        client_validate(cb) or_return
    }

    session_origin_validate(self.origin) or_return
    _, has_creator := self.created_by.?
    _, is_root := self.origin.(Session_Origin_Root)
    _, is_fork := self.origin.(Session_Origin_Fork)

    if is_root || is_fork {
        if !has_creator {
            return .Mismatched_Payload
        }
    } else {
        if has_creator {
            return .Mismatched_Payload
        }
    }

    return .None
}

// Deep-copy into `allocator`.
session_clone :: proc(self: Session, allocator := context.allocator) -> Session {
    created_by: Maybe(Client)

    if cb, ok := self.created_by.?; ok {
        created_by = client_clone(cb, allocator)
    }

    agent: Maybe(string)

    if a, ok := self.agent.?; ok {
        agent = strings.clone(a, allocator)
    }

    return Session {
        id = self.id,
        workspace_id = self.workspace_id,
        profile = strings.clone(self.profile, allocator),
        model = strings.clone(self.model, allocator),
        reasoning = strings.clone(self.reasoning, allocator),
        config_rev = self.config_rev,
        permission = self.permission,
        max_rounds = self.max_rounds,
        title = strings.clone(self.title, allocator),
        message_count = self.message_count,
        updated_at_ms = self.updated_at_ms,
        created_by = created_by,
        origin = session_origin_clone(self.origin, allocator),
        agent = agent,
    }
}

// Run settings captured at start.
Run_Config :: struct {
    // Config revision used by the run.
    config_rev: Config_Rev,

    // @bounded 128
    // Model id.
    model:      string,

    // @bounded 32
    // Reasoning level.
    reasoning:  string,
}

// Write a Run_Config object.
run_config_emit :: proc(e: ^Emitter, self: Run_Config) {
    object_begin(e)
    field_u64(e, "config_rev", u64(self.config_rev))
    field_string(e, "model", self.model)
    field_string(e, "reasoning", self.reasoning)
    object_end(e)
}

// Verify annotated field bounds.
run_config_validate :: proc(self: Run_Config) -> Validation_Error {
    enforce_bounded(128, self.model) or_return

    return enforce_bounded(32, self.reasoning)
}

// Deep-copy into `allocator`.
run_config_clone :: proc(self: Run_Config, allocator := context.allocator) -> Run_Config {
    return Run_Config {
        config_rev = self.config_rev,
        model = strings.clone(self.model, allocator),
        reasoning = strings.clone(self.reasoning, allocator),
    }
}

// Coarse live session state.
Session_Activity :: struct {
    // Current activity state.
    state:              Activity_State,

    // Config the named run is executing under. Present exactly when `state` names a run
    // that has one; absent under `idle` and `compacting`.
    config:             Maybe(Run_Config),

    // Accepted inputs waiting to run. At most LIMITS.max_queued_inputs.
    queued:             u64,

    // Provider context token count.
    context_tokens:     u64,

    // @required-nullable
    // Pending manual compaction run id.
    pending_compaction: Maybe(Run_Id),
}

// Write a Session_Activity object; `config` is omitted when absent, while
// `pending_compaction` is always present, null when absent.
session_activity_emit :: proc(e: ^Emitter, self: Session_Activity) {
    object_begin(e)
    key(e, "state")
    activity_state_emit(e, self.state)

    if cfg, ok := self.config.?; ok {
        key(e, "config")
        run_config_emit(e, cfg)
    }

    field_u64(e, "queued", self.queued)
    field_u64(e, "context_tokens", self.context_tokens)
    field_required_null_u64(e, "pending_compaction", self.pending_compaction)
    object_end(e)
}

// Verify annotated field bounds and the state/config cross-field invariant: only `idle`
// and `compacting` name no run whose config could be reported.
session_activity_validate :: proc(self: Session_Activity) -> Validation_Error {
    if self.queued > u64(LIMITS.max_queued_inputs) {
        return .Overflow
    }

    activity_state_validate(self.state) or_return

    cfg, has_config := self.config.?

    if has_config {
        run_config_validate(cfg) or_return
    }

    switch _ in self.state {
    case Activity_State_Idle, Activity_State_Compacting:
        if has_config {
            return .Mismatched_Payload
        }

    case Activity_State_Building,
         Activity_State_Running,
         Activity_State_Reasoning,
         Activity_State_Waiting_Permission,
         Activity_State_Running_Tool,
         Activity_State_Retrying:
        if !has_config {
            return .Mismatched_Payload
        }
    }

    return .None
}

// Deep-copy nested activity strings and the hoisted config into `allocator`.
session_activity_clone :: proc(self: Session_Activity, allocator := context.allocator) -> Session_Activity {
    config: Maybe(Run_Config)

    if cfg, ok := self.config.?; ok {
        config = run_config_clone(cfg, allocator)
    }

    return Session_Activity {
        state = activity_state_clone(self.state, allocator),
        config = config,
        queued = self.queued,
        context_tokens = self.context_tokens,
        pending_compaction = self.pending_compaction,
    }
}

// Full compact row returned by session.list and session-index broadcasts.
// Non-owning; nested slices share the containing frame arena.
Session_List_Item :: struct {
    // Durable session summary.
    session:  Session,

    // Current coarse activity; idle is explicit.
    activity: Session_Activity,
}

// Write a Session_List_Item object.
session_list_item_emit :: proc(e: ^Emitter, self: Session_List_Item) {
    object_begin(e)
    key(e, "session")
    session_emit(e, self.session)
    key(e, "activity")
    session_activity_emit(e, self.activity)
    object_end(e)
}

// Verify nested fixed and bounded fields.
session_list_item_validate :: proc(self: Session_List_Item) -> Validation_Error {
    session_validate(self.session) or_return

    return session_activity_validate(self.activity)
}

// Deep-copy into `allocator`.
session_list_item_clone :: proc(self: Session_List_Item, allocator := context.allocator) -> Session_List_Item {
    return Session_List_Item {
        session = session_clone(self.session, allocator),
        activity = session_activity_clone(self.activity, allocator),
    }
}

// No workspace restriction.
Session_Scope_All :: struct {}

// Sessions belonging to one exact workspace.
Session_Scope_Workspace :: struct {
    // @fixed 16
    // Workspace to match.
    workspace_id: Workspace_Id,
}

// Workspace scope searched by session.list.
Session_Scope :: union {
    Session_Scope_All,
    Session_Scope_Workspace,
}

// Write internal-tagged JSON with `type` first.
session_scope_emit :: proc(e: ^Emitter, self: Session_Scope) {
    object_begin(e)

    switch v in self {
    case Session_Scope_All:
        field_string(e, "type", "all")

    case Session_Scope_Workspace:
        field_string(e, "type", "workspace")
        field_id(e, "workspace_id", ([16]u8)(v.workspace_id))
    }

    object_end(e)
}

// Verify fixed fields.
session_scope_validate :: proc(self: Session_Scope) -> Validation_Error {
    switch v in self {
    case Session_Scope_All:
        return .None

    case Session_Scope_Workspace:
        return enforce_id(([16]u8)(v.workspace_id))
    }

    return .None
}

// User-facing conversations: root sessions and forks.
Session_Population_Top_Level :: struct {}

// Immediate persistent children of one session.
Session_Population_Children :: struct {
    // @fixed 16
    // Parent session to match.
    parent_id: Session_Id,
}

// Sessions created by one cron job.
Session_Population_Job_Runs :: struct {
    // @fixed 16
    // Cron job to match.
    job_id: Job_Id,
}

// Every session regardless of origin.
Session_Population_All :: struct {}

// Session relationship population searched by session.list.
Session_Population :: union {
    Session_Population_Top_Level,
    Session_Population_Children,
    Session_Population_Job_Runs,
    Session_Population_All,
}

// Write internal-tagged JSON with `type` first.
session_population_emit :: proc(e: ^Emitter, self: Session_Population) {
    object_begin(e)

    switch v in self {
    case Session_Population_Top_Level:
        field_string(e, "type", "top_level")

    case Session_Population_Children:
        field_string(e, "type", "children")
        field_id(e, "parent_id", ([16]u8)(v.parent_id))

    case Session_Population_Job_Runs:
        field_string(e, "type", "job_runs")
        field_id(e, "job_id", ([16]u8)(v.job_id))

    case Session_Population_All:
        field_string(e, "type", "all")
    }

    object_end(e)
}

// Verify fixed relationship ids.
session_population_validate :: proc(self: Session_Population) -> Validation_Error {
    switch v in self {
    case Session_Population_Top_Level, Session_Population_All:
        return .None

    case Session_Population_Children:
        return enforce_id(([16]u8)(v.parent_id))

    case Session_Population_Job_Runs:
        return enforce_id(([16]u8)(v.job_id))
    }

    return .None
}

// Closed daemon-defined session-list ordering.
Session_View :: enum {
    Active,
    Recent,
    Active_Recent,
}

// Session_View <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
session_view_wire := [Session_View]string {
    .Active        = "active",
    .Recent        = "recent",
    .Active_Recent = "active_recent",
}

// Wire string for a session view.
session_view_to_wire :: proc(view: Session_View) -> string {
    return session_view_wire[view]
}

// Session view for a wire string; ok is false for an unknown view.
session_view_from_wire :: proc(s: string) -> (Session_View, bool) {
    return enum_from_wire(session_view_wire, s)
}

// session.list input. Non-owning.
Session_List_Params :: struct {
    // @default Session_Scope_All{}
    // Workspace scope; omitted means no workspace restriction.
    scope:      Session_Scope,

    // @default Session_Population_Top_Level{}
    // Relationship population; omitted means user-facing top-level sessions.
    population: Session_Population,

    // @default .Active_Recent
    // Membership and ordering; omitted means active_recent.
    view:       Session_View,

    // Page size; omitted means daemon default.
    limit:      Maybe(u64),

    // @bounded LIMITS.max_session_list_cursor_bytes
    // Opaque daemon-issued continuation.
    cursor:     Maybe(string),
}

// Write session.list params.
session_list_params_emit :: proc(e: ^Emitter, self: Session_List_Params) {
    object_begin(e)
    key(e, "scope")
    session_scope_emit(e, self.scope)
    key(e, "population")
    session_population_emit(e, self.population)
    field_string(e, "view", session_view_to_wire(self.view))

    if limit, ok := self.limit.?; ok {
        field_u64(e, "limit", limit)
    }

    field_string_opt(e, "cursor", self.cursor)
    object_end(e)
}

// Verify scope, range, and cursor bound.
session_list_params_validate :: proc(self: Session_List_Params) -> Validation_Error {
    session_scope_validate(self.scope) or_return
    session_population_validate(self.population) or_return

    if limit, ok := self.limit.?; ok {
        if limit == 0 || limit > u64(LIMITS.max_session_list_page_size) {
            return .Out_Of_Range
        }
    }

    if cursor, ok := self.cursor.?; ok {
        return enforce_bounded(LIMITS.max_session_list_cursor_bytes, cursor)
    }

    return .None
}

// One bounded session.list page. Non-owning.
Session_List_Result :: struct {
    // Compact-index revision represented by every field in this result.
    revision:    Session_Revision,

    // @bounded LIMITS.max_session_list_page_size
    // Rows in final daemon-defined display order.
    items:       []Session_List_Item,

    // @required-nullable
    // @bounded LIMITS.max_session_list_cursor_bytes
    // Opaque continuation; required null on the final page.
    next_cursor: Maybe(string),

    // Unique rows in the complete selected view before paging.
    total:       u64,
}

// Write a session.list result; `next_cursor` is always present, null on the final page.
session_list_result_emit :: proc(e: ^Emitter, self: Session_List_Result) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    key(e, "items")
    array_begin(e)
    for item in self.items {
        elem(e)
        session_list_item_emit(e, item)
    }

    array_end(e)
    field_required_null_string(e, "next_cursor", self.next_cursor)
    field_u64(e, "total", self.total)
    object_end(e)
}

// Verify revision, page, and annotated field bounds.
session_list_result_validate :: proc(self: Session_List_Result) -> Validation_Error {
    if u64(self.revision) > MAX_SESSION_REVISION {
        return .Out_Of_Range
    }

    if len(self.items) > LIMITS.max_session_list_page_size {
        return .Overflow
    }

    if self.total < u64(len(self.items)) {
        return .Mismatched_Payload
    }

    for item in self.items {
        session_list_item_validate(item) or_return
    }

    if cursor, ok := self.next_cursor.?; ok {
        return enforce_bounded(LIMITS.max_session_list_cursor_bytes, cursor)
    }

    return .None
}

// No active work.
Activity_State_Idle :: struct {}

// Runtime is being built as the first phase of a run.
Activity_State_Building :: struct {
    // Active run id.
    run_id:        Run_Id,

    // Run and build start epoch ms.
    started_at_ms: u64,
}

// Run is active.
Activity_State_Running :: struct {
    // Active run id.
    run_id:        Run_Id,

    // Run start epoch ms.
    started_at_ms: u64,
}

// Model is producing reasoning.
Activity_State_Reasoning :: struct {
    // Active run id.
    run_id:     Run_Id,

    // Draft message id.
    message_id: Message_Id,

    // Reasoning part id.
    part_id:    Part_Id,
}

// Tool call awaits permission.
Activity_State_Waiting_Permission :: struct {
    // Active run id.
    run_id:          Run_Id,

    // Message containing the tool.
    message_id:      Message_Id,

    // Tool part id.
    part_id:         Part_Id,

    // @bounded 128
    // Tool name.
    tool_name:       string,

    // Request epoch ms.
    requested_at_ms: u64,
}

// Tool call is running.
Activity_State_Running_Tool :: struct {
    // Active run id.
    run_id:        Run_Id,

    // Message containing the tool.
    message_id:    Message_Id,

    // Tool part id.
    part_id:       Part_Id,

    // @bounded 128
    // Tool name.
    tool_name:     string,

    // Tool start epoch ms.
    started_at_ms: u64,
}

// Run is waiting to retry.
Activity_State_Retrying :: struct {
    // Active run id.
    run_id:       Run_Id,

    // Current attempt number.
    attempt:      u64,

    // Maximum attempts.
    max_attempts: u64,

    // Next retry epoch ms.
    next_at_ms:   u64,

    // Failure code.
    code:         Run_Error_Code,

    // @bounded LIMITS.max_activity_retry_message_bytes
    // Human-readable failure.
    message:      string,
}

// Compaction model call is active.
Activity_State_Compacting :: struct {
    // Active run id.
    run_id:        Run_Id,

    // Why compaction is running.
    reason:        Compaction_Reason,

    // Compaction start epoch ms.
    started_at_ms: u64,
}

// Session activity variant. The `message_id`, `part_id`, and `tool_name` locators are
// deliberately derivable: they are a checksum, and disagreement is a client's cue to resync.
Activity_State :: union {
    Activity_State_Idle,
    Activity_State_Building,
    Activity_State_Running,
    Activity_State_Reasoning,
    Activity_State_Waiting_Permission,
    Activity_State_Running_Tool,
    Activity_State_Retrying,
    Activity_State_Compacting,
}

// Write internal-tagged JSON with `type` first.
activity_state_emit :: proc(e: ^Emitter, self: Activity_State) {
    object_begin(e)

    switch v in self {
    case Activity_State_Idle:
        field_string(e, "type", "idle")

    case Activity_State_Building:
        field_string(e, "type", "building")
        field_u64(e, "run_id", u64(v.run_id))
        field_u64(e, "started_at_ms", v.started_at_ms)

    case Activity_State_Running:
        field_string(e, "type", "running")
        field_u64(e, "run_id", u64(v.run_id))
        field_u64(e, "started_at_ms", v.started_at_ms)

    case Activity_State_Reasoning:
        field_string(e, "type", "reasoning")
        field_u64(e, "run_id", u64(v.run_id))
        field_u64(e, "message_id", u64(v.message_id))
        field_u64(e, "part_id", u64(v.part_id))

    case Activity_State_Waiting_Permission:
        field_string(e, "type", "waiting_permission")
        field_u64(e, "run_id", u64(v.run_id))
        field_u64(e, "message_id", u64(v.message_id))
        field_u64(e, "part_id", u64(v.part_id))
        field_string(e, "tool_name", v.tool_name)
        field_u64(e, "requested_at_ms", v.requested_at_ms)

    case Activity_State_Running_Tool:
        field_string(e, "type", "running_tool")
        field_u64(e, "run_id", u64(v.run_id))
        field_u64(e, "message_id", u64(v.message_id))
        field_u64(e, "part_id", u64(v.part_id))
        field_string(e, "tool_name", v.tool_name)
        field_u64(e, "started_at_ms", v.started_at_ms)

    case Activity_State_Retrying:
        field_string(e, "type", "retrying")
        field_u64(e, "run_id", u64(v.run_id))
        field_u64(e, "attempt", v.attempt)
        field_u64(e, "max_attempts", v.max_attempts)
        field_u64(e, "next_at_ms", v.next_at_ms)
        field_string(e, "code", run_error_code_to_wire(v.code))
        field_string(e, "message", v.message)

    case Activity_State_Compacting:
        field_string(e, "type", "compacting")
        field_u64(e, "run_id", u64(v.run_id))
        field_string(e, "reason", compaction_reason_to_wire(v.reason))
        field_u64(e, "started_at_ms", v.started_at_ms)
    }

    object_end(e)
}

// Verify annotated field bounds.
activity_state_validate :: proc(self: Activity_State) -> Validation_Error {
    switch v in self {
    case Activity_State_Idle,
         Activity_State_Building,
         Activity_State_Running,
         Activity_State_Reasoning,
         Activity_State_Compacting:
        return .None

    case Activity_State_Waiting_Permission:
        return enforce_bounded(128, v.tool_name)

    case Activity_State_Running_Tool:
        return enforce_bounded(128, v.tool_name)

    case Activity_State_Retrying:
        return enforce_bounded(LIMITS.max_activity_retry_message_bytes, v.message)
    }

    return .None
}

// Deep-copy display strings into `allocator`; arms without one are copied as-is.
activity_state_clone :: proc(self: Activity_State, allocator := context.allocator) -> Activity_State {
    switch v in self {
    case Activity_State_Idle,
         Activity_State_Building,
         Activity_State_Running,
         Activity_State_Reasoning,
         Activity_State_Compacting:
        return self

    case Activity_State_Waiting_Permission:
        return Activity_State_Waiting_Permission {
            run_id = v.run_id,
            message_id = v.message_id,
            part_id = v.part_id,
            tool_name = strings.clone(v.tool_name, allocator),
            requested_at_ms = v.requested_at_ms,
        }

    case Activity_State_Running_Tool:
        return Activity_State_Running_Tool {
            run_id = v.run_id,
            message_id = v.message_id,
            part_id = v.part_id,
            tool_name = strings.clone(v.tool_name, allocator),
            started_at_ms = v.started_at_ms,
        }

    case Activity_State_Retrying:
        return Activity_State_Retrying {
            run_id = v.run_id,
            attempt = v.attempt,
            max_attempts = v.max_attempts,
            next_at_ms = v.next_at_ms,
            code = v.code,
            message = strings.clone(v.message, allocator),
        }
    }

    return nil
}

// Why compaction is running.
Compaction_Reason :: enum {
    // Daemon-triggered compaction.
    Auto,

    // User-requested compaction.
    Manual,
}

// Compaction_Reason <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
compaction_reason_wire := [Compaction_Reason]string {
    .Auto   = "auto",
    .Manual = "manual",
}

// Wire string for a compaction reason.
compaction_reason_to_wire :: proc(r: Compaction_Reason) -> string {
    return compaction_reason_wire[r]
}

// Compaction reason for a wire string; ok is false for an unknown reason.
compaction_reason_from_wire :: proc(s: string) -> (Compaction_Reason, bool) {
    return enum_from_wire(compaction_reason_wire, s)
}

// session.resync input.
Session_Resync_Params :: struct {
    // Session to resync.
    session_id: Session_Id,

    // Max messages to return; omit for daemon default.
    limit:      Maybe(u64),
}

// Write session.resync params.
session_resync_params_emit :: proc(e: ^Emitter, self: Session_Resync_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))

    if limit, ok := self.limit.?; ok {
        field_u64(e, "limit", limit)
    }

    object_end(e)
}

// Verify the session id and optional page-size bound.
session_resync_params_validate :: proc(self: Session_Resync_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    if limit, ok := self.limit.?; ok {
        if limit == 0 || limit > u64(LIMITS.max_page_size) {
            return .Out_Of_Range
        }
    }

    return .None
}

// In-flight assistant draft, resent on resync. Non-owning.
Active_Draft :: struct {
    // Draft message so far.
    message: Assistant_Message,
}

// Write an Active_Draft object.
active_draft_emit :: proc(e: ^Emitter, self: Active_Draft) {
    object_begin(e)
    key(e, "message")
    assistant_message_emit(e, self.message)
    object_end(e)
}

// Verify draft-only semantic state and aggregate live-state bounds.
active_draft_validate :: proc(self: Active_Draft) -> Validation_Error {
    return assistant_message_validate_draft(self.message)
}

// Check the activity's full run config against the draft and snapshot table.
@(private)
_activity_config_matches_draft :: proc(
    activity_config: Maybe(Run_Config),
    message: Assistant_Message,
    configs: []Run_Config,
) -> bool {
    config, has_config := activity_config.?

    if !has_config || config.config_rev != message.config_rev {
        return false
    }

    for candidate in configs {
        if candidate.config_rev != message.config_rev {
            continue
        }

        return config.model == candidate.model && config.reasoning == candidate.reasoning
    }

    return false
}

// Full session snapshot for reconnection. Non-owning.
Session_Resync_Result :: struct {
    // Current compact session-index row at this snapshot cut.
    item:                         Session_List_Item,

    // Sequence number to resume the durable stream from.
    base_seq:                     Seq,

    // @required-nullable
    // Highest message id already committed or discarded at the snapshot cut.
    // Required on the wire; null when no message has finalized.
    highest_finalized_message_id: Maybe(Message_Id),

    // @bounded LIMITS.max_page_size
    // Recent transcript messages.
    messages:                     []Message,

    // Whether older messages exist beyond `messages`.
    has_more:                     bool,

    // @bounded LIMITS.max_snapshot_configs
    // Configs referenced by `messages` and `active`.
    configs:                      []Run_Config,

    // In-flight draft, if any.
    active:                       Maybe(Active_Draft),

    // @bounded LIMITS.max_queued_inputs
    // Inputs queued behind the active turn.
    queued:                       []Queued_Input,
}

// Write a session.resync result; `highest_finalized_message_id` is always present,
// null when no message has finalized.
session_resync_result_emit :: proc(e: ^Emitter, self: Session_Resync_Result) {
    object_begin(e)
    key(e, "item")
    session_list_item_emit(e, self.item)
    field_u64(e, "base_seq", u64(self.base_seq))
    field_required_null_u64(e, "highest_finalized_message_id", self.highest_finalized_message_id)
    key(e, "messages")
    array_begin(e)
    for message in self.messages {
        elem(e)
        message_emit(e, message)
    }

    array_end(e)
    field_bool(e, "has_more", self.has_more)
    key(e, "configs")
    array_begin(e)
    for cfg in self.configs {
        elem(e)
        run_config_emit(e, cfg)
    }

    array_end(e)

    if active, ok := self.active.?; ok {
        key(e, "active")
        active_draft_emit(e, active)
    }

    key(e, "queued")
    array_begin(e)
    for q in self.queued {
        elem(e)
        queued_input_emit(e, q)
    }

    array_end(e)
    object_end(e)
}

// Verify annotated field bounds.
session_resync_result_validate :: proc(self: Session_Resync_Result) -> Validation_Error {
    session_list_item_validate(self.item) or_return

    if len(self.messages) > LIMITS.max_page_size {
        return .Overflow
    }

    for message in self.messages {
        message_validate(message) or_return
    }

    if len(self.configs) > LIMITS.max_snapshot_configs {
        return .Overflow
    }

    for cfg in self.configs {
        run_config_validate(cfg) or_return
    }

    if active, ok := self.active.?; ok {
        active_draft_validate(active) or_return
    }

    if len(self.queued) > LIMITS.max_queued_inputs {
        return .Overflow
    }

    for q in self.queued {
        queued_input_validate(q) or_return
    }

    if self.item.activity.queued != u64(len(self.queued)) {
        return .Mismatched_Payload
    }

    waiting_tools := 0

    if active, ok := self.active.?; ok {
        for part in active.message.content {
            #partial switch p in part {
            case Tool_Part:
                if _, is_waiting := p.state.(Tool_State_Waiting_Permission); is_waiting {
                    waiting_tools += 1
                }
            }
        }
    }

    // The activity's hoisted config must name the draft's revision and its content.
    if active, ok := self.active.?; ok {
        if !_activity_config_matches_draft(self.item.activity.config, active.message, self.configs) {
            return .Mismatched_Payload
        }
    }

    switch st in self.item.activity.state {
    case Activity_State_Idle, Activity_State_Building, Activity_State_Compacting:
        if _, ok := self.active.?; ok {
            return .Mismatched_Payload
        }

        if waiting_tools != 0 {
            return .Mismatched_Payload
        }

    case Activity_State_Running:
        if waiting_tools != 0 {
            return .Mismatched_Payload
        }

        if active, ok := self.active.?; ok {
            if st.run_id != active.message.run_id {
                return .Mismatched_Payload
            }
        }

    case Activity_State_Reasoning:
        if waiting_tools != 0 {
            return .Mismatched_Payload
        }

        active, ok := self.active.?

        if !ok {
            return .Mismatched_Payload
        }

        if st.run_id != active.message.run_id || st.message_id != active.message.id {
            return .Mismatched_Payload
        }

        if u64(st.part_id) >= u64(len(active.message.content)) {
            return .Mismatched_Payload
        }

        part_index := int(u64(st.part_id))
        reasoning, is_reasoning := active.message.content[part_index].(Reasoning_Part)

        if !is_reasoning {
            return .Mismatched_Payload
        }

        if reasoning.id != st.part_id {
            return .Mismatched_Payload
        }

    case Activity_State_Waiting_Permission:
        if waiting_tools != 1 {
            return .Mismatched_Payload
        }

        active, ok := self.active.?

        if !ok {
            return .Mismatched_Payload
        }

        if st.run_id != active.message.run_id || st.message_id != active.message.id {
            return .Mismatched_Payload
        }

        if u64(st.part_id) >= u64(len(active.message.content)) {
            return .Mismatched_Payload
        }

        part_index := int(u64(st.part_id))
        tool, is_tool := active.message.content[part_index].(Tool_Part)

        if !is_tool {
            return .Mismatched_Payload
        }

        if tool.id != st.part_id || tool.name != st.tool_name {
            return .Mismatched_Payload
        }

        if _, is_waiting := tool.state.(Tool_State_Waiting_Permission); !is_waiting {
            return .Mismatched_Payload
        }

        // The activity's `requested_at_ms` locates the same prompt the part carries.
        perm, has_perm := tool.permission_state.?

        if !has_perm || perm.requested_at_ms != st.requested_at_ms {
            return .Mismatched_Payload
        }

    case Activity_State_Running_Tool:
        if waiting_tools != 0 {
            return .Mismatched_Payload
        }

        active, ok := self.active.?

        if !ok {
            return .Mismatched_Payload
        }

        if st.run_id != active.message.run_id || st.message_id != active.message.id {
            return .Mismatched_Payload
        }

        if u64(st.part_id) >= u64(len(active.message.content)) {
            return .Mismatched_Payload
        }

        part_index := int(u64(st.part_id))
        tool, is_tool := active.message.content[part_index].(Tool_Part)

        if !is_tool {
            return .Mismatched_Payload
        }

        if tool.id != st.part_id || tool.name != st.tool_name {
            return .Mismatched_Payload
        }

        running, is_running := tool.state.(Tool_State_Running)

        if !is_running {
            return .Mismatched_Payload
        }

        if running.started_at_ms != st.started_at_ms {
            return .Mismatched_Payload
        }

    case Activity_State_Retrying:
        if waiting_tools != 0 {
            return .Mismatched_Payload
        }

        if active, ok := self.active.?; ok {
            if st.run_id != active.message.run_id {
                return .Mismatched_Payload
            }
        }
    }

    return .None
}

// session.history input.
Session_History_Params :: struct {
    // Session to page through.
    session_id:        Session_Id,

    // Page ends before this message (exclusive).
    before_message_id: Message_Id,

    // Max messages to return; omit for daemon default.
    limit:             Maybe(u64),
}

// Write session.history params.
session_history_params_emit :: proc(e: ^Emitter, self: Session_History_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "before_message_id", u64(self.before_message_id))

    if limit, ok := self.limit.?; ok {
        field_u64(e, "limit", limit)
    }

    object_end(e)
}

// session.history result.
Session_History_Result :: struct {
    // Session the page belongs to.
    session_id: Session_Id,

    // @bounded LIMITS.max_page_size
    // Page of transcript messages.
    messages:   []Message,

    // @bounded LIMITS.max_snapshot_configs
    // Configs referenced by `messages`.
    configs:    []Run_Config,

    // Whether older messages exist beyond this page.
    has_more:   bool,
}

// Write a session.history result.
session_history_result_emit :: proc(e: ^Emitter, self: Session_History_Result) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    key(e, "messages")
    array_begin(e)
    for message in self.messages {
        elem(e)
        message_emit(e, message)
    }

    array_end(e)
    key(e, "configs")
    array_begin(e)
    for cfg in self.configs {
        elem(e)
        run_config_emit(e, cfg)
    }

    array_end(e)
    field_bool(e, "has_more", self.has_more)
    object_end(e)
}

// Verify annotated field bounds.
session_history_result_validate :: proc(self: Session_History_Result) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    if len(self.messages) > LIMITS.max_page_size {
        return .Overflow
    }

    for message in self.messages {
        message_validate(message) or_return
    }

    if len(self.configs) > LIMITS.max_snapshot_configs {
        return .Overflow
    }

    for cfg in self.configs {
        run_config_validate(cfg) or_return
    }

    return .None
}

// session.config.get input.
Session_Config_Params :: struct {
    // Session to read config for.
    session_id: Session_Id,

    // Specific revision to fetch; omit for the live config.
    config_rev: Maybe(Config_Rev),
}

// Write session.config.get params.
session_config_params_emit :: proc(e: ^Emitter, self: Session_Config_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))

    if cr, ok := self.config_rev.?; ok {
        field_u64(e, "config_rev", u64(cr))
    }

    object_end(e)
}

// session.config.get result.
Session_Config_Result :: struct {
    // The requested run config.
    config:        Run_Config,

    // @required-nullable
    // @unbounded
    // null means no system prompt is sent to the model.
    system_prompt: Maybe(string),
}

// Write a session.config.get result; `system_prompt` is always present, null when
// no system prompt is sent to the model.
session_config_result_emit :: proc(e: ^Emitter, self: Session_Config_Result) {
    object_begin(e)
    key(e, "config")
    run_config_emit(e, self.config)
    field_required_null_string(e, "system_prompt", self.system_prompt)
    object_end(e)
}

// Verify annotated field bounds.
session_config_result_validate :: proc(self: Session_Config_Result) -> Validation_Error {
    return run_config_validate(self.config)
}

// session.subscription.set input.
Subscription_Set_Params :: struct {
    // @bounded LIMITS.max_subscriptions
    // Sessions to subscribe to; replaces the prior set.
    sessions: []Session_Id,
}

// Write session.subscription.set params.
subscription_set_params_emit :: proc(e: ^Emitter, self: Subscription_Set_Params) {
    object_begin(e)
    key(e, "sessions")
    array_begin(e)
    for sid in self.sessions {
        elem(e)
        val_id(e, ([16]u8)(sid))
    }

    array_end(e)
    object_end(e)
}

// Verify annotated field bounds.
subscription_set_params_validate :: proc(self: Subscription_Set_Params) -> Validation_Error {
    if len(self.sessions) > LIMITS.max_subscriptions {
        return .Overflow
    }

    for sid in self.sessions {
        enforce_id(([16]u8)(sid)) or_return
    }

    return .None
}

// --- streaming decoders ---

// Decode a Create_Session straight from the token stream.
create_session_from_reader :: proc(d: ^Decoder) -> (out: Create_Session, err: Validation_Error) {
    out.system_prompt = System_Prompt_Default{}
    out.max_rounds = Max_Rounds_Default{}
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_path":
            out.workspace_path = dec_string(d) or_return

        case "profile":
            out.profile = dec_string(d) or_return

        case "model":
            out.model = dec_string(d) or_return

        case "reasoning":
            out.reasoning = dec_string(d) or_return

        case "system_prompt":
            if dec_is_null(d) {
                out.system_prompt = System_Prompt_None{}
            } else {
                s := dec_string(d) or_return
                out.system_prompt = System_Prompt_Set {
                    value = s,
                }
            }

        case "permission":
            out.permission = dec_enum(d, permission_mode_wire) or_return

        case "max_rounds":
            if dec_is_null(d) {
                out.max_rounds = Max_Rounds_Unlimited{}
            } else {
                n := dec_u64(d) or_return
                out.max_rounds = Max_Rounds_Set {
                    value = n,
                }
            }

        case:
            dec_skip(d) or_return
        }
    }

    return out, .None
}

// Decode a Session_Patch straight from the token stream.
session_patch_from_reader :: proc(d: ^Decoder) -> (patch: Session_Patch, err: Validation_Error) {
    patch.max_rounds = Max_Rounds_Default{}
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "model":
            patch.model = dec_string(d) or_return

        case "reasoning":
            patch.reasoning = dec_string(d) or_return

        case "permission":
            patch.permission = dec_enum(d, permission_mode_wire) or_return

        case "max_rounds":
            if dec_is_null(d) {
                patch.max_rounds = Max_Rounds_Unlimited{}
            } else {
                n := dec_u64(d) or_return
                patch.max_rounds = Max_Rounds_Set {
                    value = n,
                }
            }

        case:
            dec_skip(d) or_return
        }
    }

    return patch, .None
}

// Decode session.fork params straight from the token stream.
session_fork_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Fork_Params, err: Validation_Error) {
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

        case "before_message_id":
            params.before_message_id = Message_Id(dec_u64(d) or_return)

        case:
            dec_skip(d) or_return
        }
    }

    if .Sid not_in seen {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode session.compact params straight from the token stream.
session_compact_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Compact_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.compact result straight from the token stream.
session_compact_result_from_reader :: proc(d: ^Decoder) -> (result: Session_Compact_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Status,
        Run,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "status":
            result.status = dec_enum(d, compact_status_wire) or_return
            seen += {.Status}

        case "run_id":
            result.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Status, .Run} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode session.rewind params straight from the token stream.
session_rewind_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Rewind_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Before,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "before_message_id":
            params.before_message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Before}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Before} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode internally-tagged session origin straight from the token stream.
session_origin_from_reader :: proc(d: ^Decoder) -> (origin: Session_Origin, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "root":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "parent_id", "parent_message_id", "parent_part_id", "source_id", "job_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Session_Origin_Root{}, .None

    case "child":
        pid: [16]u8
        mid, pt: u64
        Field :: enum {
            Pid,
            Mid,
            Pt,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "parent_id":
                pid = dec_fixed(d, 16) or_return
                seen += {.Pid}

            case "parent_message_id":
                mid = dec_u64(d) or_return
                seen += {.Mid}

            case "parent_part_id":
                pt = dec_u64(d) or_return
                seen += {.Pt}

            case "source_id", "job_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Pid, .Mid, .Pt} {
            return nil, .Mismatched_Payload
        }

        return Session_Origin_Child {
                parent_id = Session_Id(pid),
                parent_message_id = Message_Id(mid),
                parent_part_id = Part_Id(pt),
            },
            .None

    case "fork":
        sid: [16]u8
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "source_id":
                sid = dec_fixed(d, 16) or_return
                have = true

            case "parent_id", "parent_message_id", "parent_part_id", "job_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Session_Origin_Fork{source_id = Session_Id(sid)}, .None

    case "cron":
        jid: [16]u8
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "job_id":
                jid = dec_fixed(d, 16) or_return
                have = true

            case "parent_id", "parent_message_id", "parent_part_id", "source_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Session_Origin_Cron{job_id = Job_Id(jid)}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a Session straight from the token stream.
session_from_reader :: proc(d: ^Decoder) -> (out: Session, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Wid,
        Profile,
        Model,
        Reasoning,
        Cfg,
        Perm,
        Max,
        Title,
        Count,
        Updated,
        Created,
        Origin,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            out.id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "workspace_id":
            out.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
            seen += {.Wid}

        case "profile":
            out.profile = dec_string(d) or_return
            seen += {.Profile}

        case "model":
            out.model = dec_string(d) or_return
            seen += {.Model}

        case "reasoning":
            out.reasoning = dec_string(d) or_return
            seen += {.Reasoning}

        case "config_rev":
            out.config_rev = Config_Rev(dec_u64(d) or_return)
            seen += {.Cfg}

        case "permission":
            out.permission = dec_enum(d, permission_mode_wire) or_return
            seen += {.Perm}

        case "max_rounds":
            seen += {.Max}

            if !dec_is_null(d) {
                out.max_rounds = dec_u64(d) or_return
            }

        case "title":
            out.title = dec_string(d) or_return
            seen += {.Title}

        case "message_count":
            out.message_count = dec_u64(d) or_return
            seen += {.Count}

        case "updated_at_ms":
            out.updated_at_ms = dec_u64(d) or_return
            seen += {.Updated}

        case "created_by":
            seen += {.Created}

            if !dec_is_null(d) {
                out.created_by = client_from_reader(d) or_return
            }

        case "origin":
            out.origin = session_origin_from_reader(d) or_return
            seen += {.Origin}

        case "agent":
            out.agent = dec_string(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if seen !=
       {.Id, .Wid, .Profile, .Model, .Reasoning, .Cfg, .Perm, .Max, .Title, .Count, .Updated, .Created, .Origin} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode a Run_Config straight from the token stream.
run_config_from_reader :: proc(d: ^Decoder) -> (out: Run_Config, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Cfg,
        Model,
        Reasoning,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "config_rev":
            out.config_rev = Config_Rev(dec_u64(d) or_return)
            seen += {.Cfg}

        case "model":
            out.model = dec_string(d) or_return
            seen += {.Model}

        case "reasoning":
            out.reasoning = dec_string(d) or_return
            seen += {.Reasoning}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Cfg, .Model, .Reasoning} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode a Session_Activity straight from the token stream.
session_activity_from_reader :: proc(d: ^Decoder) -> (out: Session_Activity, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        State,
        Queued,
        Ctx,
        Pc,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "state":
            out.state = activity_state_from_reader(d) or_return
            seen += {.State}

        case "config":
            out.config = run_config_from_reader(d) or_return

        case "queued":
            out.queued = dec_u64(d) or_return
            seen += {.Queued}

        case "context_tokens":
            out.context_tokens = dec_u64(d) or_return
            seen += {.Ctx}

        case "pending_compaction":
            seen += {.Pc}

            if !dec_is_null(d) {
                out.pending_compaction = Run_Id(dec_u64(d) or_return)
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.State, .Queued, .Ctx, .Pc} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode a Session_List_Item straight from the token stream.
session_list_item_from_reader :: proc(d: ^Decoder) -> (out: Session_List_Item, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Session,
        Activity,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session":
            out.session = session_from_reader(d) or_return
            seen += {.Session}

        case "activity":
            out.activity = session_activity_from_reader(d) or_return
            seen += {.Activity}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Session, .Activity} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode internally-tagged session scope straight from the token stream.
session_scope_from_reader :: proc(d: ^Decoder) -> (scope: Session_Scope, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "all":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "workspace_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Session_Scope_All{}, .None

    case "workspace":
        wid: [16]u8
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "workspace_id":
                wid = dec_fixed(d, 16) or_return
                have = true

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Session_Scope_Workspace{workspace_id = Workspace_Id(wid)}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode internally-tagged session population straight from the token stream.
session_population_from_reader :: proc(d: ^Decoder) -> (population: Session_Population, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "top_level":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "parent_id", "job_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Session_Population_Top_Level{}, .None

    case "children":
        pid: [16]u8
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "parent_id":
                pid = dec_fixed(d, 16) or_return
                have = true

            case "job_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Session_Population_Children{parent_id = Session_Id(pid)}, .None

    case "job_runs":
        jid: [16]u8
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "job_id":
                jid = dec_fixed(d, 16) or_return
                have = true

            case "parent_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Session_Population_Job_Runs{job_id = Job_Id(jid)}, .None

    case "all":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "parent_id", "job_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Session_Population_All{}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode session.list params straight from the token stream, applying defaults.
session_list_params_from_reader :: proc(d: ^Decoder) -> (params: Session_List_Params, err: Validation_Error) {
    params.scope = Session_Scope_All{}
    params.population = Session_Population_Top_Level{}
    params.view = .Active_Recent
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "scope":
            params.scope = session_scope_from_reader(d) or_return

        case "population":
            params.population = session_population_from_reader(d) or_return

        case "view":
            params.view = dec_enum(d, session_view_wire) or_return

        case "limit":
            params.limit = dec_u64(d) or_return

        case "cursor":
            params.cursor = dec_string(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    return params, .None
}

// Decode a session.list result straight from the token stream.
session_list_result_from_reader :: proc(d: ^Decoder) -> (result: Session_List_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Items,
        Next,
        Total,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            result.revision = Session_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "items":
            result.items = dec_array(d, session_list_item_from_reader) or_return
            seen += {.Items}

        case "next_cursor":
            seen += {.Next}

            if !dec_is_null(d) {
                result.next_cursor = dec_string(d) or_return
            }

        case "total":
            result.total = dec_u64(d) or_return
            seen += {.Total}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Items, .Next, .Total} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode internally-tagged activity state straight from the token stream.
activity_state_from_reader :: proc(d: ^Decoder) -> (state: Activity_State, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "idle":
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "started_at_ms",
                 "run_id",
                 "config",
                 "message_id",
                 "part_id",
                 "tool_name",
                 "requested_at_ms",
                 "attempt",
                 "max_attempts",
                 "next_at_ms",
                 "code",
                 "message",
                 "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        return Activity_State_Idle{}, .None

    case "building", "running":
        st_run: Run_Id
        st_start: u64

        Field :: enum {
            Run,
            Start,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "run_id":
                st_run = Run_Id(dec_u64(d) or_return)
                seen += {.Run}

            case "started_at_ms":
                st_start = dec_u64(d) or_return
                seen += {.Start}
            case "config",
                 "message_id",
                 "part_id",
                 "tool_name",
                 "requested_at_ms",
                 "attempt",
                 "max_attempts",
                 "next_at_ms",
                 "code",
                 "message",
                 "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Run, .Start} {
            return nil, .Mismatched_Payload
        }

        if tag == "building" {
            return Activity_State_Building{run_id = st_run, started_at_ms = st_start}, .None
        }

        return Activity_State_Running{run_id = st_run, started_at_ms = st_start}, .None

    case "reasoning":
        st: Activity_State_Reasoning

        Field :: enum {
            Run,
            Mid,
            Pid,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "run_id":
                st.run_id = Run_Id(dec_u64(d) or_return)
                seen += {.Run}

            case "message_id":
                st.message_id = Message_Id(dec_u64(d) or_return)
                seen += {.Mid}

            case "part_id":
                st.part_id = Part_Id(dec_u64(d) or_return)
                seen += {.Pid}
            case "config",
                 "started_at_ms",
                 "tool_name",
                 "requested_at_ms",
                 "attempt",
                 "max_attempts",
                 "next_at_ms",
                 "code",
                 "message",
                 "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Run, .Mid, .Pid} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "waiting_permission":
        st: Activity_State_Waiting_Permission

        Field :: enum {
            Run,
            Mid,
            Pid,
            Tool,
            Req,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "run_id":
                st.run_id = Run_Id(dec_u64(d) or_return)
                seen += {.Run}

            case "message_id":
                st.message_id = Message_Id(dec_u64(d) or_return)
                seen += {.Mid}

            case "part_id":
                st.part_id = Part_Id(dec_u64(d) or_return)
                seen += {.Pid}

            case "tool_name":
                st.tool_name = dec_string(d) or_return
                seen += {.Tool}

            case "requested_at_ms":
                st.requested_at_ms = dec_u64(d) or_return
                seen += {.Req}

            case "config", "started_at_ms", "attempt", "max_attempts", "next_at_ms", "code", "message", "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Run, .Mid, .Pid, .Tool, .Req} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "running_tool":
        st: Activity_State_Running_Tool

        Field :: enum {
            Run,
            Mid,
            Pid,
            Tool,
            Start,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "run_id":
                st.run_id = Run_Id(dec_u64(d) or_return)
                seen += {.Run}

            case "message_id":
                st.message_id = Message_Id(dec_u64(d) or_return)
                seen += {.Mid}

            case "part_id":
                st.part_id = Part_Id(dec_u64(d) or_return)
                seen += {.Pid}

            case "tool_name":
                st.tool_name = dec_string(d) or_return
                seen += {.Tool}

            case "started_at_ms":
                st.started_at_ms = dec_u64(d) or_return
                seen += {.Start}

            case "config", "requested_at_ms", "attempt", "max_attempts", "next_at_ms", "code", "message", "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Run, .Mid, .Pid, .Tool, .Start} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "retrying":
        st: Activity_State_Retrying

        Field :: enum {
            Run,
            Att,
            Max,
            Next,
            Code,
            Msg,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "run_id":
                st.run_id = Run_Id(dec_u64(d) or_return)
                seen += {.Run}

            case "attempt":
                st.attempt = dec_u64(d) or_return
                seen += {.Att}

            case "max_attempts":
                st.max_attempts = dec_u64(d) or_return
                seen += {.Max}

            case "next_at_ms":
                st.next_at_ms = dec_u64(d) or_return
                seen += {.Next}

            case "code":
                st.code = dec_enum(d, run_error_code_wire) or_return
                seen += {.Code}

            case "message":
                st.message = dec_string(d) or_return
                seen += {.Msg}

            case "config", "started_at_ms", "message_id", "part_id", "tool_name", "requested_at_ms", "reason":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Run, .Att, .Max, .Next, .Code, .Msg} {
            return nil, .Mismatched_Payload
        }

        return st, .None

    case "compacting":
        st: Activity_State_Compacting

        Field :: enum {
            Run,
            Reason,
            Start,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "run_id":
                st.run_id = Run_Id(dec_u64(d) or_return)
                seen += {.Run}

            case "reason":
                st.reason = dec_enum(d, compaction_reason_wire) or_return
                seen += {.Reason}

            case "started_at_ms":
                st.started_at_ms = dec_u64(d) or_return
                seen += {.Start}
            case "config",
                 "message_id",
                 "part_id",
                 "tool_name",
                 "requested_at_ms",
                 "attempt",
                 "max_attempts",
                 "next_at_ms",
                 "code",
                 "message":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Run, .Reason, .Start} {
            return nil, .Mismatched_Payload
        }

        return st, .None
    }

    return nil, .Mismatched_Payload
}

// Decode session.resync params straight from the token stream.
session_resync_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Resync_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            have = true

        case "limit":
            params.limit = dec_u64(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode an Active_Draft straight from the token stream.
active_draft_from_reader :: proc(d: ^Decoder) -> (draft: Active_Draft, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "message":
            draft.message = assistant_message_from_reader(d) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return draft, .None
}

// Decode a session.resync result straight from the token stream.
session_resync_result_from_reader :: proc(d: ^Decoder) -> (result: Session_Resync_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Item,
        Seq,
        Hf,
        Msgs,
        More,
        Cfgs,
        Queued,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "item":
            result.item = session_list_item_from_reader(d) or_return
            seen += {.Item}

        case "base_seq":
            result.base_seq = Seq(dec_u64(d) or_return)
            seen += {.Seq}

        case "highest_finalized_message_id":
            seen += {.Hf}

            if !dec_is_null(d) {
                result.highest_finalized_message_id = Message_Id(dec_u64(d) or_return)
            }

        case "messages":
            result.messages = dec_array(d, message_from_reader) or_return
            seen += {.Msgs}

        case "has_more":
            result.has_more = dec_bool(d) or_return
            seen += {.More}

        case "configs":
            result.configs = dec_array(d, run_config_from_reader) or_return
            seen += {.Cfgs}

        case "active":
            result.active = active_draft_from_reader(d) or_return

        case "queued":
            result.queued = dec_array(d, queued_input_from_reader) or_return
            seen += {.Queued}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Item, .Seq, .Hf, .Msgs, .More, .Cfgs, .Queued} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode session.history params straight from the token stream.
session_history_params_from_reader :: proc(d: ^Decoder) -> (params: Session_History_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Before,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "before_message_id":
            params.before_message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Before}

        case "limit":
            params.limit = dec_u64(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Before} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.history result straight from the token stream.
session_history_result_from_reader :: proc(d: ^Decoder) -> (result: Session_History_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Msgs,
        Cfgs,
        More,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            result.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "messages":
            result.messages = dec_array(d, message_from_reader) or_return
            seen += {.Msgs}

        case "configs":
            result.configs = dec_array(d, run_config_from_reader) or_return
            seen += {.Cfgs}

        case "has_more":
            result.has_more = dec_bool(d) or_return
            seen += {.More}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Msgs, .Cfgs, .More} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode session.config.get params straight from the token stream.
session_config_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Config_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            have = true

        case "config_rev":
            params.config_rev = Config_Rev(dec_u64(d) or_return)

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.config.get result straight from the token stream.
session_config_result_from_reader :: proc(d: ^Decoder) -> (result: Session_Config_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Cfg,
        Sp,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "config":
            result.config = run_config_from_reader(d) or_return
            seen += {.Cfg}

        case "system_prompt":
            seen += {.Sp}

            if !dec_is_null(d) {
                result.system_prompt = dec_string(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Cfg, .Sp} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode session.subscription.set params straight from the token stream.
@(private)
_session_id_from_reader :: proc(d: ^Decoder) -> (out: Session_Id, err: Validation_Error) {
    out = Session_Id(dec_fixed(d, 16) or_return)

    return out, .None
}

subscription_set_params_from_reader :: proc(d: ^Decoder) -> (params: Subscription_Set_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "sessions":
            params.sessions = dec_array(d, _session_id_from_reader) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}
