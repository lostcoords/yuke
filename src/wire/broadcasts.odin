package wire

import "core:strings"

// Closed enum of broadcast names. Source of truth for the broadcast set.
Broadcast_Name :: enum {
    // Durable session summary changed.
    Session_Summary_Changed,

    // Volatile session activity changed.
    Session_Activity_Changed,

    // Session was removed.
    Session_Removed,

    // Workspace became known to the daemon.
    Workspace_Created,

    // Workspace was removed.
    Workspace_Removed,

    // Permission rules for a workspace changed.
    Permission_Rules_Changed,

    // Catalog content hash or health changed.
    Catalog_Changed,

    // Cron job was created.
    Cron_Created,

    // Cron job was updated.
    Cron_Updated,

    // Cron job was removed.
    Cron_Removed,

    // Daemon diagnostic notice.
    Notice,

    // Committed transcript message; durable.
    Message_Committed,

    // Run started; durable.
    Run_Started,

    // Run reached a terminal outcome; durable.
    Run_Done,

    // Run config changed; durable.
    Config_Changed,

    // Transcript was truncated; durable.
    Transcript_Truncated,

    // Assistant message draft started.
    Message_Started,

    // Assistant message draft was discarded (e.g. retry).
    Message_Discarded,

    // A new part was appended to a draft.
    Message_Part_Added,

    // Incremental text/reasoning bytes for a draft.
    Message_Part_Delta,

    // Tool part state changed.
    Tool_State_Changed,

    // Incremental display output for a running tool part.
    Tool_Output_Delta,

    // Input was queued behind the active turn.
    Input_Queued,

    // Queued input was canceled before starting.
    Input_Canceled,
}

// Broadcast_Name <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
broadcast_name_wire := [Broadcast_Name]string {
    .Session_Summary_Changed  = "session.summary_changed",
    .Session_Activity_Changed = "session.activity_changed",
    .Session_Removed          = "session.removed",
    .Workspace_Created        = "workspace.created",
    .Workspace_Removed        = "workspace.removed",
    .Permission_Rules_Changed = "permission.rules_changed",
    .Catalog_Changed          = "catalog.changed",
    .Cron_Created             = "cron.created",
    .Cron_Updated             = "cron.updated",
    .Cron_Removed             = "cron.removed",
    .Notice                   = "notice",
    .Message_Committed        = "message.committed",
    .Run_Started              = "run.started",
    .Run_Done                 = "run.done",
    .Config_Changed           = "config.changed",
    .Transcript_Truncated     = "transcript.truncated",
    .Message_Started          = "message.started",
    .Message_Discarded        = "message.discarded",
    .Message_Part_Added       = "message.part_added",
    .Message_Part_Delta       = "message.part_delta",
    .Tool_State_Changed       = "tool.state_changed",
    .Tool_Output_Delta        = "tool.output_delta",
    .Input_Queued             = "input.queued",
    .Input_Canceled           = "input.canceled",
}

// Wire string for a broadcast name.
broadcast_name_to_wire :: proc(n: Broadcast_Name) -> string {
    return broadcast_name_wire[n]
}

// Broadcast name for a wire string; ok is false for an unknown name.
broadcast_name_from_wire :: proc(s: string) -> (Broadcast_Name, bool) {
    return enum_from_wire(broadcast_name_wire, s)
}

// Delivery class of a broadcast: how it is sequenced, gated, and whether it may be
// shed under send backpressure.
Broadcast_Class :: enum {
    // Sequenced, persisted before broadcast, never dropped, subscription-gated.
    Durable_Gated,

    // Unsequenced, never replayed, subscription-gated.
    Live_Gated,

    // Offset-checked live delta the daemon may drop; a drop shows as an offset gap
    // so the receiver resyncs rather than corrupting. Subscription-gated.
    Live_Droppable,

    // Delivered regardless of subscription.
    Ungated,
}

// Delivery class for a broadcast name. One switch is the single source of truth for
// sequencing, gating, and droppability; the send path sheds only `Live_Droppable`.
broadcast_name_class :: proc(name: Broadcast_Name) -> Broadcast_Class {
    switch name {
    case .Message_Committed, .Run_Started, .Run_Done, .Config_Changed, .Transcript_Truncated:
        return .Durable_Gated
    case .Message_Part_Delta, .Tool_Output_Delta:
        return .Live_Droppable
    case .Message_Started,
         .Message_Discarded,
         .Message_Part_Added,
         .Tool_State_Changed,
         .Input_Queued,
         .Input_Canceled:
        return .Live_Gated
    case .Session_Summary_Changed,
         .Session_Activity_Changed,
         .Session_Removed,
         .Workspace_Created,
         .Workspace_Removed,
         .Permission_Rules_Changed,
         .Catalog_Changed,
         .Cron_Created,
         .Cron_Updated,
         .Cron_Removed,
         .Notice:
        return .Ungated
    }

    unreachable()
}

// Whether a class is delivered only to connections subscribed to the payload's session. The
// send path consults this; a gated broadcast without a session id is a bug, not a wide send.
broadcast_class_gated :: proc(class: Broadcast_Class) -> bool {
    switch class {
    case .Durable_Gated, .Live_Gated, .Live_Droppable:
        return true

    case .Ungated:
        return false
    }

    unreachable()
}

// Whether the send path may shed a frame of this class under backpressure. The receiver detects
// the loss by offset and resyncs; no other class may skip a frame.
broadcast_class_droppable :: proc(class: Broadcast_Class) -> bool {
    switch class {
    case .Live_Droppable:
        return true

    case .Durable_Gated, .Live_Gated, .Ungated:
        return false
    }

    unreachable()
}

// Typed broadcast payloads. One struct per broadcast name; a broadcast frame's data
// is always exactly one of these.

// Payload for `session.summary_changed`.
Session_Summary_Changed_Data :: struct {
    // Daemon-lifetime compact-index revision.
    revision: Session_Revision,

    // Current durable session summary.
    session:  Session,
}

// Write a session.summary_changed payload.
session_summary_changed_data_emit :: proc(e: ^Emitter, self: Session_Summary_Changed_Data) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    key(e, "session")
    session_emit(e, self.session)
    object_end(e)
}

// Verify revision range and nested summary fields.
session_summary_changed_data_validate :: proc(self: Session_Summary_Changed_Data) -> Validation_Error {
    if self.revision == 0 || u64(self.revision) > MAX_SESSION_REVISION {
        return .Out_Of_Range
    }

    return session_validate(self.session)
}

// Payload for `session.activity_changed`.
Session_Activity_Changed_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Current coarse activity.
    activity:   Session_Activity,
}

// Write a session.activity_changed payload.
session_activity_changed_data_emit :: proc(e: ^Emitter, self: Session_Activity_Changed_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    key(e, "activity")
    session_activity_emit(e, self.activity)
    object_end(e)
}

// Verify the session id and nested activity fields.
session_activity_changed_data_validate :: proc(self: Session_Activity_Changed_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return session_activity_validate(self.activity)
}

// Payload for `session.removed`.
Session_Removed_Data :: struct {
    // Daemon-lifetime compact-index revision.
    revision:   Session_Revision,

    // Id of the removed session.
    session_id: Session_Id,
}

// Write a session.removed payload.
session_removed_data_emit :: proc(e: ^Emitter, self: Session_Removed_Data) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    field_id(e, "session_id", ([16]u8)(self.session_id))
    object_end(e)
}

// Verify revision range and the session id.
session_removed_data_validate :: proc(self: Session_Removed_Data) -> Validation_Error {
    if self.revision == 0 || u64(self.revision) > MAX_SESSION_REVISION {
        return .Out_Of_Range
    }

    return enforce_id(([16]u8)(self.session_id))
}

// Payload for `workspace.created`.
Workspace_Created_Data :: struct {
    // The newly known workspace.
    workspace: Workspace,
}

// Write a workspace.created payload.
workspace_created_data_emit :: proc(e: ^Emitter, self: Workspace_Created_Data) {
    object_begin(e)
    key(e, "workspace")
    workspace_emit(e, self.workspace)
    object_end(e)
}

// Verify nested workspace fields.
workspace_created_data_validate :: proc(self: Workspace_Created_Data) -> Validation_Error {
    return workspace_validate(self.workspace)
}

// Payload for `workspace.removed`.
Workspace_Removed_Data :: struct {
    // Id of the removed workspace.
    workspace_id: Workspace_Id,
}

// Write a workspace.removed payload.
workspace_removed_data_emit :: proc(e: ^Emitter, self: Workspace_Removed_Data) {
    object_begin(e)
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    object_end(e)
}

// Verify the workspace id.
workspace_removed_data_validate :: proc(self: Workspace_Removed_Data) -> Validation_Error {
    return enforce_id(([16]u8)(self.workspace_id))
}

// Payload for `permission.rules_changed`.
Permission_Rules_Changed_Data :: struct {
    // Owning workspace id.
    workspace_id: Workspace_Id,

    // @bounded LIMITS.max_permission_rules
    // Current rule set.
    rules:        []Permission_Rule,
}

// Write a permission.rules_changed payload.
permission_rules_changed_data_emit :: proc(e: ^Emitter, self: Permission_Rules_Changed_Data) {
    object_begin(e)
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    key(e, "rules")
    array_begin(e)
    for rule in self.rules {
        elem(e)
        permission_rule_emit(e, rule)
    }

    array_end(e)
    object_end(e)
}

// Verify the workspace id, rule count, and each rule.
permission_rules_changed_data_validate :: proc(self: Permission_Rules_Changed_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.workspace_id)) or_return

    if len(self.rules) > LIMITS.max_permission_rules {
        return .Overflow
    }

    for rule in self.rules {
        permission_rule_validate(rule) or_return
    }

    return .None
}

// Payload for `catalog.changed`.
Catalog_Changed_Data :: struct {
    // New catalog content hash.
    catalog_rev: Catalog_Rev,

    // Updated load health.
    health:      Catalog_Health,
}

// Write a catalog.changed payload.
catalog_changed_data_emit :: proc(e: ^Emitter, self: Catalog_Changed_Data) {
    object_begin(e)
    field_id(e, "catalog_rev", ([64]u8)(self.catalog_rev))
    key(e, "health")
    catalog_health_emit(e, self.health)
    object_end(e)
}

// Verify the catalog hash and nested health fields.
catalog_changed_data_validate :: proc(self: Catalog_Changed_Data) -> Validation_Error {
    enforce_id(([64]u8)(self.catalog_rev)) or_return

    return catalog_health_validate(self.health)
}

// Payload for `cron.created`.
Cron_Created_Data :: struct {
    // Daemon-lifetime cron-index revision.
    revision: Cron_Revision,

    // The newly created job.
    job:      Cron_Job,
}

// Write a cron.created payload.
cron_created_data_emit :: proc(e: ^Emitter, self: Cron_Created_Data) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    key(e, "job")
    cron_job_emit(e, self.job)
    object_end(e)
}

// Verify revision range and nested job fields.
cron_created_data_validate :: proc(self: Cron_Created_Data) -> Validation_Error {
    if self.revision == 0 || u64(self.revision) > MAX_CRON_REVISION {
        return .Out_Of_Range
    }

    return cron_job_validate(self.job)
}

// Payload for `cron.updated`.
Cron_Updated_Data :: struct {
    // Daemon-lifetime cron-index revision.
    revision: Cron_Revision,

    // Updated job record.
    job:      Cron_Job,
}

// Write a cron.updated payload.
cron_updated_data_emit :: proc(e: ^Emitter, self: Cron_Updated_Data) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    key(e, "job")
    cron_job_emit(e, self.job)
    object_end(e)
}

// Verify revision range and nested job fields.
cron_updated_data_validate :: proc(self: Cron_Updated_Data) -> Validation_Error {
    if self.revision == 0 || u64(self.revision) > MAX_CRON_REVISION {
        return .Out_Of_Range
    }

    return cron_job_validate(self.job)
}

// Payload for `cron.removed`.
Cron_Removed_Data :: struct {
    // Daemon-lifetime cron-index revision.
    revision: Cron_Revision,

    // Id of the removed job.
    job_id:   Job_Id,
}

// Write a cron.removed payload.
cron_removed_data_emit :: proc(e: ^Emitter, self: Cron_Removed_Data) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    field_id(e, "job_id", ([16]u8)(self.job_id))
    object_end(e)
}

// Verify revision range and the job id.
cron_removed_data_validate :: proc(self: Cron_Removed_Data) -> Validation_Error {
    if self.revision == 0 || u64(self.revision) > MAX_CRON_REVISION {
        return .Out_Of_Range
    }

    return enforce_id(([16]u8)(self.job_id))
}

// Payload for `message.committed`.
Message_Committed_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Sequence number on the durable stream.
    seq:        Seq,

    // The committed message.
    message:    Message,
}

// Write a message.committed payload.
message_committed_data_emit :: proc(e: ^Emitter, self: Message_Committed_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "seq", u64(self.seq))
    key(e, "message")
    message_emit(e, self.message)
    object_end(e)
}

// Verify the session id and nested message fields.
message_committed_data_validate :: proc(self: Message_Committed_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return message_validate(self.message)
}

// Payload for `run.started`.
Run_Started_Data :: struct {
    // Owning session id.
    session_id:    Session_Id,

    // Sequence number on the durable stream.
    seq:           Seq,

    // New run id.
    run_id:        Run_Id,

    // What kind of run started.
    kind:          Run_Kind,

    // Config revision used by the run.
    config_rev:    Config_Rev,

    // Start epoch ms.
    started_at_ms: u64,
}

// Write a run.started payload.
run_started_data_emit :: proc(e: ^Emitter, self: Run_Started_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "seq", u64(self.seq))
    field_u64(e, "run_id", u64(self.run_id))
    field_string(e, "kind", run_kind_to_wire(self.kind))
    field_u64(e, "config_rev", u64(self.config_rev))
    field_u64(e, "started_at_ms", self.started_at_ms)
    object_end(e)
}

// Verify the session id.
run_started_data_validate :: proc(self: Run_Started_Data) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Payload for `run.done`. One terminal event for a run: `outcome` carries the
// terminal arm (turn, compacted, skipped, canceled, or failed) and `timing` covers
// every terminal, including a queued run canceled before it started.
Run_Done_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Sequence number on the durable stream.
    seq:        Seq,

    // Run id (terminal).
    run_id:     Run_Id,

    // What kind of run terminated.
    kind:       Run_Kind,

    // Terminal timing; `started_at_ms` is null when canceled while queued.
    timing:     Run_Canceled_Timing,

    // Terminal outcome.
    outcome:    Run_Outcome,
}

// Write a run.done payload.
run_done_data_emit :: proc(e: ^Emitter, self: Run_Done_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "seq", u64(self.seq))
    field_u64(e, "run_id", u64(self.run_id))
    field_string(e, "kind", run_kind_to_wire(self.kind))
    key(e, "timing")
    run_canceled_timing_emit(e, self.timing)
    key(e, "outcome")
    run_outcome_emit(e, self.outcome)
    object_end(e)
}

// Verify the session id and nested outcome bounds.
run_done_data_validate :: proc(self: Run_Done_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return run_outcome_validate(self.outcome)
}

// Payload for `config.changed`.
Config_Changed_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Sequence number on the durable stream.
    seq:        Seq,

    // New active run config.
    config:     Run_Config,
}

// Write a config.changed payload.
config_changed_data_emit :: proc(e: ^Emitter, self: Config_Changed_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "seq", u64(self.seq))
    key(e, "config")
    run_config_emit(e, self.config)
    object_end(e)
}

// Verify the session id and nested config fields.
config_changed_data_validate :: proc(self: Config_Changed_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return run_config_validate(self.config)
}

// Payload for `transcript.truncated`.
Transcript_Truncated_Data :: struct {
    // Owning session id.
    session_id:       Session_Id,

    // Sequence number on the durable stream.
    seq:              Seq,

    // First removed message id.
    first_removed_id: Message_Id,
}

// Write a transcript.truncated payload.
transcript_truncated_data_emit :: proc(e: ^Emitter, self: Transcript_Truncated_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "seq", u64(self.seq))
    field_u64(e, "first_removed_id", u64(self.first_removed_id))
    object_end(e)
}

// Verify the session id.
transcript_truncated_data_validate :: proc(self: Transcript_Truncated_Data) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Payload for `message.started` (draft opened).
Message_Started_Data :: struct {
    // Owning session id.
    session_id:    Session_Id,

    // Draft message id.
    message_id:    Message_Id,

    // Owning run id.
    run_id:        Run_Id,

    // Config revision used.
    config_rev:    Config_Rev,

    // @bounded 64
    // Agent name, e.g. `"main"`.
    agent:         string,

    // Draft creation epoch ms.
    created_at_ms: u64,
}

// Write a message.started payload.
message_started_data_emit :: proc(e: ^Emitter, self: Message_Started_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "message_id", u64(self.message_id))
    field_u64(e, "run_id", u64(self.run_id))
    field_u64(e, "config_rev", u64(self.config_rev))
    field_string(e, "agent", self.agent)
    field_u64(e, "created_at_ms", self.created_at_ms)
    object_end(e)
}

// Verify the session id.
message_started_data_validate :: proc(self: Message_Started_Data) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Payload for `message.discarded`.
Message_Discarded_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Discarded draft id.
    message_id: Message_Id,
}

// Write a message.discarded payload.
message_discarded_data_emit :: proc(e: ^Emitter, self: Message_Discarded_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "message_id", u64(self.message_id))
    object_end(e)
}

// Verify the session id.
message_discarded_data_validate :: proc(self: Message_Discarded_Data) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Payload for `message.part_added`.
Message_Part_Added_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Draft message id.
    message_id: Message_Id,

    // Newly appended part.
    part:       Assistant_Part,
}

// Write a message.part_added payload.
message_part_added_data_emit :: proc(e: ^Emitter, self: Message_Part_Added_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "message_id", u64(self.message_id))
    key(e, "part")
    assistant_part_emit(e, self.part)
    object_end(e)
}

// Verify the session id and nested part fields.
message_part_added_data_validate :: proc(self: Message_Part_Added_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return assistant_part_validate(self.part)
}

// Payload for `message.part_delta`: incremental draft bytes folded by UTF-8 offset.
Message_Part_Delta_Data :: distinct Part_Delta

// Payload for `tool.state_changed`.
Tool_State_Changed_Data :: struct {
    // Owning session id.
    session_id:       Session_Id,

    // Draft message id.
    message_id:       Message_Id,

    // Tool part ordinal inside the message.
    part_id:          Part_Id,

    // New tool state.
    state:            Tool_State,

    // The part's permission lifecycle at this transition, under the same
    // `Tool_Part` cross-field invariant. Replaces the part's copy wholesale.
    permission_state: Maybe(Permission_State),
}

// Write a tool.state_changed payload.
tool_state_changed_data_emit :: proc(e: ^Emitter, self: Tool_State_Changed_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "message_id", u64(self.message_id))
    field_u64(e, "part_id", u64(self.part_id))
    key(e, "state")
    tool_state_emit(e, self.state)

    if p, ok := self.permission_state.?; ok {
        key(e, "permission")
        _permission_state_emit(e, p)
    }

    object_end(e)
}

// Verify the session id, nested tool state fields, and the permission cross-field invariant.
tool_state_changed_data_validate :: proc(self: Tool_State_Changed_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return
    tool_state_validate(self.state) or_return

    return tool_permission_state_validate(self.state, self.permission_state)
}

// Payload for `tool.output_delta`: incremental display output for a running tool
// part, offset-folded like `message.part_delta` but targeting the tool output stream.
Tool_Output_Delta_Data :: distinct Part_Delta

// Payload for `input.queued`.
Input_Queued_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // The queued input.
    input:      Queued_Input,
}

// Write an input.queued payload.
input_queued_data_emit :: proc(e: ^Emitter, self: Input_Queued_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    key(e, "input")
    queued_input_emit(e, self.input)
    object_end(e)
}

// Verify the session id and nested input fields.
input_queued_data_validate :: proc(self: Input_Queued_Data) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return queued_input_validate(self.input)
}

// Payload for `input.canceled`.
Input_Canceled_Data :: struct {
    // Owning session id.
    session_id: Session_Id,

    // Id of the canceled input.
    input_id:   Input_Id,
}

// Write an input.canceled payload.
input_canceled_data_emit :: proc(e: ^Emitter, self: Input_Canceled_Data) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "input_id", u64(self.input_id))
    object_end(e)
}

// Verify the session id.
input_canceled_data_validate :: proc(self: Input_Canceled_Data) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Typed broadcast payload, tagged by broadcast name on the frame. A broadcast
// frame's data is always exactly one of these variants.
Broadcast_Data :: union {
    Session_Summary_Changed_Data,
    Session_Activity_Changed_Data,
    Session_Removed_Data,
    Workspace_Created_Data,
    Workspace_Removed_Data,
    Permission_Rules_Changed_Data,
    Catalog_Changed_Data,
    Cron_Created_Data,
    Cron_Updated_Data,
    Cron_Removed_Data,
    Notice,
    Message_Committed_Data,
    Run_Started_Data,
    Run_Done_Data,
    Config_Changed_Data,
    Transcript_Truncated_Data,
    Message_Started_Data,
    Message_Discarded_Data,
    Message_Part_Added_Data,
    Message_Part_Delta_Data,
    Tool_State_Changed_Data,
    Tool_Output_Delta_Data,
    Input_Queued_Data,
    Input_Canceled_Data,
}

// Write just the active payload's fields (no tag wrapper).
broadcast_data_emit :: proc(e: ^Emitter, self: Broadcast_Data) {
    switch v in self {
    case Session_Summary_Changed_Data:
        session_summary_changed_data_emit(e, v)

    case Session_Activity_Changed_Data:
        session_activity_changed_data_emit(e, v)

    case Session_Removed_Data:
        session_removed_data_emit(e, v)

    case Workspace_Created_Data:
        workspace_created_data_emit(e, v)

    case Workspace_Removed_Data:
        workspace_removed_data_emit(e, v)

    case Permission_Rules_Changed_Data:
        permission_rules_changed_data_emit(e, v)

    case Catalog_Changed_Data:
        catalog_changed_data_emit(e, v)

    case Cron_Created_Data:
        cron_created_data_emit(e, v)

    case Cron_Updated_Data:
        cron_updated_data_emit(e, v)

    case Cron_Removed_Data:
        cron_removed_data_emit(e, v)

    case Notice:
        notice_emit(e, v)

    case Message_Committed_Data:
        message_committed_data_emit(e, v)

    case Run_Started_Data:
        run_started_data_emit(e, v)

    case Run_Done_Data:
        run_done_data_emit(e, v)

    case Config_Changed_Data:
        config_changed_data_emit(e, v)

    case Transcript_Truncated_Data:
        transcript_truncated_data_emit(e, v)

    case Message_Started_Data:
        message_started_data_emit(e, v)

    case Message_Discarded_Data:
        message_discarded_data_emit(e, v)

    case Message_Part_Added_Data:
        message_part_added_data_emit(e, v)

    case Message_Part_Delta_Data:
        part_delta_emit(e, Part_Delta(v))

    case Tool_State_Changed_Data:
        tool_state_changed_data_emit(e, v)

    case Tool_Output_Delta_Data:
        part_delta_emit(e, Part_Delta(v))

    case Input_Queued_Data:
        input_queued_data_emit(e, v)

    case Input_Canceled_Data:
        input_canceled_data_emit(e, v)
    }
}

// Verify nested bounded/fixed fields for the active broadcast variant.
broadcast_data_validate :: proc(self: Broadcast_Data) -> Validation_Error {
    switch v in self {
    case Session_Summary_Changed_Data:
        return session_summary_changed_data_validate(v)

    case Session_Activity_Changed_Data:
        return session_activity_changed_data_validate(v)

    case Session_Removed_Data:
        return session_removed_data_validate(v)

    case Workspace_Created_Data:
        return workspace_created_data_validate(v)

    case Workspace_Removed_Data:
        return workspace_removed_data_validate(v)

    case Permission_Rules_Changed_Data:
        return permission_rules_changed_data_validate(v)

    case Catalog_Changed_Data:
        return catalog_changed_data_validate(v)

    case Cron_Created_Data:
        return cron_created_data_validate(v)

    case Cron_Updated_Data:
        return cron_updated_data_validate(v)

    case Cron_Removed_Data:
        return cron_removed_data_validate(v)

    case Notice:
        return notice_validate(v)

    case Message_Committed_Data:
        return message_committed_data_validate(v)

    case Run_Started_Data:
        return run_started_data_validate(v)

    case Run_Done_Data:
        return run_done_data_validate(v)

    case Config_Changed_Data:
        return config_changed_data_validate(v)

    case Transcript_Truncated_Data:
        return transcript_truncated_data_validate(v)

    case Message_Started_Data:
        return message_started_data_validate(v)

    case Message_Discarded_Data:
        return message_discarded_data_validate(v)

    case Message_Part_Added_Data:
        return message_part_added_data_validate(v)

    case Message_Part_Delta_Data:
        return part_delta_validate(Part_Delta(v))

    case Tool_State_Changed_Data:
        return tool_state_changed_data_validate(v)

    case Tool_Output_Delta_Data:
        return part_delta_validate(Part_Delta(v))

    case Input_Queued_Data:
        return input_queued_data_validate(v)

    case Input_Canceled_Data:
        return input_canceled_data_validate(v)
    }

    return .None
}

// Deep-copy a broadcast payload into `allocator`; pure-value arms are copied as-is.
broadcast_data_clone :: proc(self: Broadcast_Data, allocator := context.allocator) -> Broadcast_Data {
    switch v in self {
    case Session_Summary_Changed_Data:
        return Session_Summary_Changed_Data{revision = v.revision, session = session_clone(v.session, allocator)}

    case Session_Activity_Changed_Data:
        return Session_Activity_Changed_Data {
            session_id = v.session_id,
            activity = session_activity_clone(v.activity, allocator),
        }

    case Session_Removed_Data:
        return v

    case Workspace_Created_Data:
        return Workspace_Created_Data{workspace = workspace_clone(v.workspace, allocator)}

    case Workspace_Removed_Data:
        return v

    case Permission_Rules_Changed_Data:
        rules := make([]Permission_Rule, len(v.rules), allocator)
        for i in 0 ..< len(rules) {
            rules[i] = permission_rule_clone(v.rules[i], allocator)
        }
        return Permission_Rules_Changed_Data{workspace_id = v.workspace_id, rules = rules}

    case Catalog_Changed_Data:
        return Catalog_Changed_Data{catalog_rev = v.catalog_rev, health = catalog_health_clone(v.health, allocator)}

    case Cron_Created_Data:
        return Cron_Created_Data{revision = v.revision, job = cron_job_clone(v.job, allocator)}

    case Cron_Updated_Data:
        return Cron_Updated_Data{revision = v.revision, job = cron_job_clone(v.job, allocator)}

    case Cron_Removed_Data:
        return v

    case Notice:
        return notice_clone(v, allocator)

    case Message_Committed_Data:
        return Message_Committed_Data {
            session_id = v.session_id,
            seq = v.seq,
            message = message_clone(v.message, allocator),
        }

    case Run_Started_Data:
        return v

    case Run_Done_Data:
        return Run_Done_Data {
            session_id = v.session_id,
            seq = v.seq,
            run_id = v.run_id,
            kind = v.kind,
            timing = v.timing,
            outcome = run_outcome_clone(v.outcome, allocator),
        }

    case Config_Changed_Data:
        return Config_Changed_Data {
            session_id = v.session_id,
            seq = v.seq,
            config = run_config_clone(v.config, allocator),
        }

    case Transcript_Truncated_Data:
        return v

    case Message_Started_Data:
        out := v
        out.agent = strings.clone(v.agent, allocator)
        return out

    case Message_Discarded_Data:
        return v

    case Message_Part_Added_Data:
        return Message_Part_Added_Data {
            session_id = v.session_id,
            message_id = v.message_id,
            part = assistant_part_clone(v.part, allocator),
        }

    case Message_Part_Delta_Data:
        return Message_Part_Delta_Data(part_delta_clone(Part_Delta(v), allocator))

    case Tool_State_Changed_Data:
        permission_state: Maybe(Permission_State)

        if p, ok := v.permission_state.?; ok {
            permission_state = permission_state_clone(p, allocator)
        }

        return Tool_State_Changed_Data {
            session_id = v.session_id,
            message_id = v.message_id,
            part_id = v.part_id,
            state = tool_state_clone(v.state, allocator),
            permission_state = permission_state,
        }

    case Tool_Output_Delta_Data:
        return Tool_Output_Delta_Data(part_delta_clone(Part_Delta(v), allocator))

    case Input_Queued_Data:
        return Input_Queued_Data{session_id = v.session_id, input = queued_input_clone(v.input, allocator)}

    case Input_Canceled_Data:
        return v
    }

    return nil
}

// Broadcast name determined by this payload's active arm; ok is false for an empty
// payload. The pairing is one-to-one.
broadcast_data_name :: proc(self: Broadcast_Data) -> (Broadcast_Name, bool) {
    switch v in self {
    case Session_Summary_Changed_Data:
        return .Session_Summary_Changed, true

    case Session_Activity_Changed_Data:
        return .Session_Activity_Changed, true

    case Session_Removed_Data:
        return .Session_Removed, true

    case Workspace_Created_Data:
        return .Workspace_Created, true

    case Workspace_Removed_Data:
        return .Workspace_Removed, true

    case Permission_Rules_Changed_Data:
        return .Permission_Rules_Changed, true

    case Catalog_Changed_Data:
        return .Catalog_Changed, true

    case Cron_Created_Data:
        return .Cron_Created, true

    case Cron_Updated_Data:
        return .Cron_Updated, true

    case Cron_Removed_Data:
        return .Cron_Removed, true

    case Notice:
        return .Notice, true

    case Message_Committed_Data:
        return .Message_Committed, true

    case Run_Started_Data:
        return .Run_Started, true

    case Run_Done_Data:
        return .Run_Done, true

    case Config_Changed_Data:
        return .Config_Changed, true

    case Transcript_Truncated_Data:
        return .Transcript_Truncated, true

    case Message_Started_Data:
        return .Message_Started, true

    case Message_Discarded_Data:
        return .Message_Discarded, true

    case Message_Part_Added_Data:
        return .Message_Part_Added, true

    case Message_Part_Delta_Data:
        return .Message_Part_Delta, true

    case Tool_State_Changed_Data:
        return .Tool_State_Changed, true

    case Tool_Output_Delta_Data:
        return .Tool_Output_Delta, true

    case Input_Queued_Data:
        return .Input_Queued, true

    case Input_Canceled_Data:
        return .Input_Canceled, true
    }

    return {}, false
}

// Durable sequence number, or none for a non-durable broadcast.
broadcast_data_seq :: proc(self: Broadcast_Data) -> Maybe(Seq) {
    #partial switch v in self {
    case Message_Committed_Data:
        return v.seq

    case Run_Started_Data:
        return v.seq

    case Run_Done_Data:
        return v.seq

    case Config_Changed_Data:
        return v.seq

    case Transcript_Truncated_Data:
        return v.seq
    }

    return nil
}

// Owning session id, or none for a global or other-domain broadcast.
broadcast_data_session_id :: proc(self: Broadcast_Data) -> Maybe(Session_Id) {
    #partial switch v in self {
    case Session_Summary_Changed_Data:
        return v.session.id

    case Session_Activity_Changed_Data:
        return v.session_id

    case Session_Removed_Data:
        return v.session_id

    case Message_Committed_Data:
        return v.session_id

    case Run_Started_Data:
        return v.session_id

    case Run_Done_Data:
        return v.session_id

    case Config_Changed_Data:
        return v.session_id

    case Transcript_Truncated_Data:
        return v.session_id

    case Message_Started_Data:
        return v.session_id

    case Message_Discarded_Data:
        return v.session_id

    case Message_Part_Added_Data:
        return v.session_id

    case Message_Part_Delta_Data:
        return Part_Delta(v).session_id

    case Tool_State_Changed_Data:
        return v.session_id

    case Tool_Output_Delta_Data:
        return Part_Delta(v).session_id

    case Input_Queued_Data:
        return v.session_id

    case Input_Canceled_Data:
        return v.session_id
    }

    return nil
}

// --- streaming decoders ---

session_summary_changed_data_from_reader :: proc(
    d: ^Decoder,
) -> (
    out: Session_Summary_Changed_Data,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Session,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            out.revision = Session_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "session":
            out.session = session_from_reader(d) or_return
            seen += {.Session}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Session} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

session_activity_changed_data_from_reader :: proc(
    d: ^Decoder,
) -> (
    out: Session_Activity_Changed_Data,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Act,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "activity":
            out.activity = session_activity_from_reader(d) or_return
            seen += {.Act}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Act} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

session_removed_data_from_reader :: proc(d: ^Decoder) -> (out: Session_Removed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Sid,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            out.revision = Session_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Sid} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

workspace_created_data_from_reader :: proc(d: ^Decoder) -> (out: Workspace_Created_Data, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace":
            out.workspace = workspace_from_reader(d) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

workspace_removed_data_from_reader :: proc(d: ^Decoder) -> (out: Workspace_Removed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            out.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

permission_rules_changed_data_from_reader :: proc(
    d: ^Decoder,
) -> (
    out: Permission_Rules_Changed_Data,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return

    Field :: enum {
        Wid,
        Rules,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            out.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
            seen += {.Wid}

        case "rules":
            out.rules = dec_array(d, permission_rule_from_reader) or_return
            seen += {.Rules}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Wid, .Rules} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

catalog_changed_data_from_reader :: proc(d: ^Decoder) -> (out: Catalog_Changed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Health,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "catalog_rev":
            out.catalog_rev = Catalog_Rev(dec_fixed(d, 64) or_return)
            seen += {.Rev}

        case "health":
            out.health = catalog_health_from_reader(d) or_return
            seen += {.Health}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Health} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

cron_created_data_from_reader :: proc(d: ^Decoder) -> (out: Cron_Created_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Job,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            out.revision = Cron_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "job":
            out.job = cron_job_from_reader(d) or_return
            seen += {.Job}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Job} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

cron_updated_data_from_reader :: proc(d: ^Decoder) -> (out: Cron_Updated_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Job,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            out.revision = Cron_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "job":
            out.job = cron_job_from_reader(d) or_return
            seen += {.Job}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Job} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

cron_removed_data_from_reader :: proc(d: ^Decoder) -> (out: Cron_Removed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Jid,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            out.revision = Cron_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "job_id":
            out.job_id = Job_Id(dec_fixed(d, 16) or_return)
            seen += {.Jid}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Jid} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

message_committed_data_from_reader :: proc(d: ^Decoder) -> (out: Message_Committed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Seq,
        Msg,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "seq":
            out.seq = Seq(dec_u64(d) or_return)
            seen += {.Seq}

        case "message":
            out.message = message_from_reader(d) or_return
            seen += {.Msg}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Seq, .Msg} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

run_started_data_from_reader :: proc(d: ^Decoder) -> (out: Run_Started_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Seq,
        Run,
        Kind,
        Cfg,
        Start,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "seq":
            out.seq = Seq(dec_u64(d) or_return)
            seen += {.Seq}

        case "run_id":
            out.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case "kind":
            out.kind = dec_enum(d, run_kind_wire) or_return
            seen += {.Kind}

        case "config_rev":
            out.config_rev = Config_Rev(dec_u64(d) or_return)
            seen += {.Cfg}

        case "started_at_ms":
            out.started_at_ms = dec_u64(d) or_return
            seen += {.Start}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Seq, .Run, .Kind, .Cfg, .Start} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

run_done_data_from_reader :: proc(d: ^Decoder) -> (out: Run_Done_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Seq,
        Run,
        Kind,
        Timing,
        Outcome,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "seq":
            out.seq = Seq(dec_u64(d) or_return)
            seen += {.Seq}

        case "run_id":
            out.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case "kind":
            out.kind = dec_enum(d, run_kind_wire) or_return
            seen += {.Kind}

        case "timing":
            out.timing = run_canceled_timing_from_reader(d) or_return
            seen += {.Timing}

        case "outcome":
            out.outcome = run_outcome_from_reader(d) or_return
            seen += {.Outcome}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Seq, .Run, .Kind, .Timing, .Outcome} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

config_changed_data_from_reader :: proc(d: ^Decoder) -> (out: Config_Changed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Seq,
        Cfg,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "seq":
            out.seq = Seq(dec_u64(d) or_return)
            seen += {.Seq}

        case "config":
            out.config = run_config_from_reader(d) or_return
            seen += {.Cfg}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Seq, .Cfg} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

transcript_truncated_data_from_reader :: proc(d: ^Decoder) -> (out: Transcript_Truncated_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Seq,
        First,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "seq":
            out.seq = Seq(dec_u64(d) or_return)
            seen += {.Seq}

        case "first_removed_id":
            out.first_removed_id = Message_Id(dec_u64(d) or_return)
            seen += {.First}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Seq, .First} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

message_started_data_from_reader :: proc(d: ^Decoder) -> (out: Message_Started_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Run,
        Cfg,
        Agent,
        Created,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            out.message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Mid}

        case "run_id":
            out.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case "config_rev":
            out.config_rev = Config_Rev(dec_u64(d) or_return)
            seen += {.Cfg}

        case "agent":
            out.agent = dec_string(d) or_return
            seen += {.Agent}

        case "created_at_ms":
            out.created_at_ms = dec_u64(d) or_return
            seen += {.Created}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Run, .Cfg, .Agent, .Created} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

message_discarded_data_from_reader :: proc(d: ^Decoder) -> (out: Message_Discarded_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            out.message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Mid}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

message_part_added_data_from_reader :: proc(d: ^Decoder) -> (out: Message_Part_Added_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Part,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            out.message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Mid}

        case "part":
            out.part = assistant_part_from_reader(d) or_return
            seen += {.Part}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Part} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

tool_state_changed_data_from_reader :: proc(d: ^Decoder) -> (out: Tool_State_Changed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Pid,
        State,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            out.message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Mid}

        case "part_id":
            out.part_id = Part_Id(dec_u64(d) or_return)
            seen += {.Pid}

        case "state":
            out.state = tool_state_from_reader(d) or_return
            seen += {.State}

        case "permission":
            out.permission_state = _permission_state_from_reader(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Pid, .State} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

input_queued_data_from_reader :: proc(d: ^Decoder) -> (out: Input_Queued_Data, err: Validation_Error) {
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
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "input":
            out.input = queued_input_from_reader(d) or_return
            seen += {.Input}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Input} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

input_canceled_data_from_reader :: proc(d: ^Decoder) -> (out: Input_Canceled_Data, err: Validation_Error) {
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
            out.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "input_id":
            out.input_id = Input_Id(dec_u64(d) or_return)
            seen += {.Input}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Input} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode typed broadcast payload for `name` straight from the token stream.
broadcast_data_from_reader :: proc(
    name: Broadcast_Name,
    d: ^Decoder,
) -> (
    data: Broadcast_Data,
    err: Validation_Error,
) {
    switch name {
    case .Session_Summary_Changed:
        data = session_summary_changed_data_from_reader(d) or_return

    case .Session_Activity_Changed:
        data = session_activity_changed_data_from_reader(d) or_return

    case .Session_Removed:
        data = session_removed_data_from_reader(d) or_return

    case .Workspace_Created:
        data = workspace_created_data_from_reader(d) or_return

    case .Workspace_Removed:
        data = workspace_removed_data_from_reader(d) or_return

    case .Permission_Rules_Changed:
        data = permission_rules_changed_data_from_reader(d) or_return

    case .Catalog_Changed:
        data = catalog_changed_data_from_reader(d) or_return

    case .Cron_Created:
        data = cron_created_data_from_reader(d) or_return

    case .Cron_Updated:
        data = cron_updated_data_from_reader(d) or_return

    case .Cron_Removed:
        data = cron_removed_data_from_reader(d) or_return

    case .Notice:
        data = notice_from_reader(d) or_return

    case .Message_Committed:
        data = message_committed_data_from_reader(d) or_return

    case .Run_Started:
        data = run_started_data_from_reader(d) or_return

    case .Run_Done:
        data = run_done_data_from_reader(d) or_return

    case .Config_Changed:
        data = config_changed_data_from_reader(d) or_return

    case .Transcript_Truncated:
        data = transcript_truncated_data_from_reader(d) or_return

    case .Message_Started:
        data = message_started_data_from_reader(d) or_return

    case .Message_Discarded:
        data = message_discarded_data_from_reader(d) or_return

    case .Message_Part_Added:
        data = message_part_added_data_from_reader(d) or_return

    case .Message_Part_Delta:
        pd := part_delta_from_reader(d) or_return
        data = Message_Part_Delta_Data(pd)

    case .Tool_State_Changed:
        data = tool_state_changed_data_from_reader(d) or_return

    case .Tool_Output_Delta:
        pd := part_delta_from_reader(d) or_return
        data = Tool_Output_Delta_Data(pd)

    case .Input_Queued:
        data = input_queued_data_from_reader(d) or_return

    case .Input_Canceled:
        data = input_canceled_data_from_reader(d) or_return
    }

    return
}
