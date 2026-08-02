package wire

import "core:strings"

// Optional-field patch applied to an existing cron job.
Cron_Patch :: struct {
    // @bounded 128
    // New display name, if changing.
    name:             Maybe(string),

    // New fire schedule, if changing.
    schedule:         Cron_Schedule,

    // New session template, if changing.
    session:          Maybe(Create_Session),

    // New retention policy, if changing.
    retain:           Maybe(Cron_Retain),

    // New fire input, if changing.
    input:            Input,

    // New missed-fire policy, if changing.
    on_missed:        Maybe(Cron_Missed_Policy),

    // New overlap policy, if changing.
    overlap:          Maybe(Cron_Overlap),

    // New auto-delete-after-run flag, if changing.
    delete_after_run: Maybe(bool),

    // New enabled state, if changing.
    enabled:          Maybe(bool),
}

// Write only fields present in the patch.
cron_patch_emit :: proc(e: ^Emitter, self: Cron_Patch) {
    object_begin(e)
    field_string_opt(e, "name", self.name)

    if self.schedule != nil {
        key(e, "schedule")
        cron_schedule_emit(e, self.schedule)
    }

    if s, ok := self.session.?; ok {
        key(e, "session")
        create_session_emit(e, s)
    }

    if r, ok := self.retain.?; ok {
        field_string(e, "retain", cron_retain_to_wire(r))
    }

    if self.input != nil {
        key(e, "input")
        input_emit(e, self.input)
    }

    if m, ok := self.on_missed.?; ok {
        field_string(e, "on_missed", cron_missed_policy_to_wire(m))
    }

    if o, ok := self.overlap.?; ok {
        field_string(e, "overlap", cron_overlap_to_wire(o))
    }

    if b, ok := self.delete_after_run.?; ok {
        field_bool(e, "delete_after_run", b)
    }

    if b, ok := self.enabled.?; ok {
        field_bool(e, "enabled", b)
    }

    object_end(e)
}

// Verify annotated field bounds.
cron_patch_validate :: proc(self: Cron_Patch) -> Validation_Error {
    if n, ok := self.name.?; ok {
        enforce_bounded(128, n) or_return
    }

    if s, ok := self.session.?; ok {
        create_session_validate(s) or_return
    }

    if self.input != nil {
        return input_validate(self.input)
    }

    return .None
}

// Params for `cron.create`.
Cron_Create_Params :: struct {
    // Full spec for the new job.
    spec: Cron_Job_Spec,
}

// Write cron.create params.
cron_create_params_emit :: proc(e: ^Emitter, self: Cron_Create_Params) {
    object_begin(e)
    key(e, "spec")
    cron_job_spec_emit(e, self.spec)
    object_end(e)
}

// Verify annotated field bounds.
cron_create_params_validate :: proc(self: Cron_Create_Params) -> Validation_Error {
    return cron_job_spec_validate(self.spec)
}

// Params for `cron.patch`.
Cron_Patch_Params :: struct {
    // Job to patch.
    job_id: Job_Id,

    // Fields to change.
    patch:  Cron_Patch,
}

// Write cron.patch params.
cron_patch_params_emit :: proc(e: ^Emitter, self: Cron_Patch_Params) {
    object_begin(e)
    field_id(e, "job_id", ([16]u8)(self.job_id))
    key(e, "patch")
    cron_patch_emit(e, self.patch)
    object_end(e)
}

// Verify the target id and nested patch.
cron_patch_params_validate :: proc(self: Cron_Patch_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.job_id)) or_return

    return cron_patch_validate(self.patch)
}

// Params naming a cron job and nothing else. Shared by `cron.remove` and
// `cron.run_now`; split it the moment one of them needs a field of its own.
Cron_Job_Ref :: struct {
    // @fixed 16
    // Job the request targets.
    job_id: Job_Id,
}

// Write a cron job reference.
cron_job_ref_emit :: proc(e: ^Emitter, self: Cron_Job_Ref) {
    object_begin(e)
    field_id(e, "job_id", ([16]u8)(self.job_id))
    object_end(e)
}

// Verify the target id.
cron_job_ref_validate :: proc(self: Cron_Job_Ref) -> Validation_Error {
    return enforce_id(([16]u8)(self.job_id))
}

// Params for `cron.list`.
Cron_List_Params :: struct {
    // Page size; omitted means daemon default.
    limit:  Maybe(u64),

    // @bounded LIMITS.max_cron_list_cursor_bytes
    // Opaque continuation.
    cursor: Maybe(string),
}

// Write cron.list params.
cron_list_params_emit :: proc(e: ^Emitter, self: Cron_List_Params) {
    object_begin(e)

    if limit, ok := self.limit.?; ok {
        field_u64(e, "limit", limit)
    }

    field_string_opt(e, "cursor", self.cursor)
    object_end(e)
}

// Verify the page and cursor bounds.
cron_list_params_validate :: proc(self: Cron_List_Params) -> Validation_Error {
    if limit, ok := self.limit.?; ok {
        if limit == 0 || limit > u64(LIMITS.max_cron_list_page_size) {
            return .Out_Of_Range
        }
    }

    if cursor, ok := self.cursor.?; ok {
        return enforce_bounded(LIMITS.max_cron_list_cursor_bytes, cursor)
    }

    return .None
}

// Result of `cron.list`.
Cron_List_Result :: struct {
    // Cron-index revision represented by every job in this page.
    revision:    Cron_Revision,

    // @bounded LIMITS.max_cron_list_page_size
    // Jobs in daemon-defined stable order.
    jobs:        []Cron_Job,

    // @required-nullable
    // @bounded LIMITS.max_cron_list_cursor_bytes
    // Opaque continuation; required null on the final page.
    next_cursor: Maybe(string),
}

// Write a cron.list result; `next_cursor` is always present, null on the final page.
cron_list_result_emit :: proc(e: ^Emitter, self: Cron_List_Result) {
    object_begin(e)
    field_u64(e, "revision", u64(self.revision))
    key(e, "jobs")
    array_begin(e)
    for job in self.jobs {
        elem(e)
        cron_job_emit(e, job)
    }

    array_end(e)
    field_required_null_string(e, "next_cursor", self.next_cursor)
    object_end(e)
}

// Verify annotated field bounds.
cron_list_result_validate :: proc(self: Cron_List_Result) -> Validation_Error {
    if u64(self.revision) > MAX_CRON_REVISION {
        return .Out_Of_Range
    }

    if len(self.jobs) > LIMITS.max_cron_list_page_size {
        return .Overflow
    }

    for job in self.jobs {
        cron_job_validate(job) or_return
    }

    if cursor, ok := self.next_cursor.?; ok {
        return enforce_bounded(LIMITS.max_cron_list_cursor_bytes, cursor)
    }

    return .None
}

// Result of `cron.run_now`.
Cron_Run_Now_Result :: struct {
    // @fixed 16
    // Session created by the fire.
    session_id: Session_Id,

    // Run started in that session.
    run_id:     Run_Id,
}

// Write a cron.run_now result.
cron_run_now_result_emit :: proc(e: ^Emitter, self: Cron_Run_Now_Result) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "run_id", u64(self.run_id))
    object_end(e)
}

// Verify annotated field bounds.
cron_run_now_result_validate :: proc(self: Cron_Run_Now_Result) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Whether a fired session should be retained after the run ends.
Cron_Retain :: enum {
    // Always keep.
    Always,

    // Keep only if the run failed.
    On_Failure,

    // Always prune after the run.
    Never,
}

// Cron_Retain <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
cron_retain_wire := [Cron_Retain]string {
    .Always     = "always",
    .On_Failure = "on_failure",
    .Never      = "never",
}

// Wire string for a retention policy.
cron_retain_to_wire :: proc(r: Cron_Retain) -> string {
    return cron_retain_wire[r]
}

// Retention policy for a wire string; ok is false for an unknown policy.
cron_retain_from_wire :: proc(s: string) -> (Cron_Retain, bool) {
    return enum_from_wire(cron_retain_wire, s)
}

// Behavior when a new fire overlaps an active run.
Cron_Overlap :: enum {
    // Skip the new fire.
    Skip,

    // Run them in parallel.
    Parallel,
}

// Cron_Overlap <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
cron_overlap_wire := [Cron_Overlap]string {
    .Skip     = "skip",
    .Parallel = "parallel",
}

// Wire string for an overlap policy.
cron_overlap_to_wire :: proc(o: Cron_Overlap) -> string {
    return cron_overlap_wire[o]
}

// Overlap policy for a wire string; ok is false for an unknown policy.
cron_overlap_from_wire :: proc(s: string) -> (Cron_Overlap, bool) {
    return enum_from_wire(cron_overlap_wire, s)
}

// What to do with a fire missed while offline / behind.
Cron_Missed_Policy :: enum {
    // Drop missed fires.
    Skip,

    // Run once immediately on recovery, then resume the schedule.
    Run_Once,
}

// Cron_Missed_Policy <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
cron_missed_policy_wire := [Cron_Missed_Policy]string {
    .Skip     = "skip",
    .Run_Once = "run_once",
}

// Wire string for a missed-fire policy.
cron_missed_policy_to_wire :: proc(m: Cron_Missed_Policy) -> string {
    return cron_missed_policy_wire[m]
}

// Missed-fire policy for a wire string; ok is false for an unknown policy.
cron_missed_policy_from_wire :: proc(s: string) -> (Cron_Missed_Policy, bool) {
    return enum_from_wire(cron_missed_policy_wire, s)
}

// Outcome tag for a single cron fire.
Cron_Run_Outcome :: enum {
    // Run finished normally.
    Completed,

    // Run was canceled mid-flight.
    Canceled,

    // Run returned an error.
    Failed,

    // Daemon could not dispatch the fire (e.g. workspace busy).
    Dispatch_Failed,
}

// Cron_Run_Outcome <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
cron_run_outcome_wire := [Cron_Run_Outcome]string {
    .Completed       = "completed",
    .Canceled        = "canceled",
    .Failed          = "failed",
    .Dispatch_Failed = "dispatch_failed",
}

// Wire string for a fire outcome.
cron_run_outcome_to_wire :: proc(o: Cron_Run_Outcome) -> string {
    return cron_run_outcome_wire[o]
}

// Fire outcome for a wire string; ok is false for an unknown outcome.
cron_run_outcome_from_wire :: proc(s: string) -> (Cron_Run_Outcome, bool) {
    return enum_from_wire(cron_run_outcome_wire, s)
}

Cron_Schedule_Every :: struct {
    // Interval in ms.
    interval_ms: u64,
}

Cron_Schedule_Cron :: struct {
    // @unbounded
    // Cron expression (UTC unless `utc_offset_minutes` overrides).
    expr:               string,

    // Local-zone offset in minutes; 0 means UTC.
    utc_offset_minutes: i64,
}

Cron_Schedule_At :: struct {
    // Fire at this absolute epoch ms.
    at_ms: u64,
}

Cron_Schedule_After :: struct {
    // Delay in ms after the trigger.
    delay_ms: u64,
}

// A cron schedule: recurring or one-shot. Non-owning.
Cron_Schedule :: union {
    Cron_Schedule_Every,
    Cron_Schedule_Cron,
    Cron_Schedule_At,
    Cron_Schedule_After,
}

// Write internally-tagged JSON with `type` first.
cron_schedule_emit :: proc(e: ^Emitter, self: Cron_Schedule) {
    object_begin(e)

    switch v in self {
    case Cron_Schedule_Every:
        field_string(e, "type", "every")
        field_u64(e, "interval_ms", v.interval_ms)

    case Cron_Schedule_Cron:
        field_string(e, "type", "cron")
        field_string(e, "expr", v.expr)
        field_i64(e, "utc_offset_minutes", v.utc_offset_minutes)

    case Cron_Schedule_At:
        field_string(e, "type", "at")
        field_u64(e, "at_ms", v.at_ms)

    case Cron_Schedule_After:
        field_string(e, "type", "after")
        field_u64(e, "delay_ms", v.delay_ms)
    }

    object_end(e)
}

// Deep-copy into `allocator`. Only `cron` owns a slice.
cron_schedule_clone :: proc(self: Cron_Schedule, allocator := context.allocator) -> Cron_Schedule {
    #partial switch v in self {
    case Cron_Schedule_Cron:
        return Cron_Schedule_Cron{expr = strings.clone(v.expr, allocator), utc_offset_minutes = v.utc_offset_minutes}
    }

    return self
}

// Full spec for a cron job.
Cron_Job_Spec :: struct {
    // @bounded 128
    // Display name for the job.
    name:             Maybe(string),

    // When to fire.
    schedule:         Cron_Schedule,

    // Session template applied to each fire.
    session:          Create_Session,

    // Whether to retain fired sessions.
    retain:           Cron_Retain,

    // Input to deliver on each fire.
    input:            Input,

    // Policy when a fire is missed.
    on_missed:        Cron_Missed_Policy,

    // Policy when a new fire overlaps an active one.
    overlap:          Cron_Overlap,

    // Auto-delete the job after a successful run.
    delete_after_run: bool,
}

// Write a Cron_Job_Spec object.
cron_job_spec_emit :: proc(e: ^Emitter, self: Cron_Job_Spec) {
    object_begin(e)
    field_string_opt(e, "name", self.name)
    key(e, "schedule")
    cron_schedule_emit(e, self.schedule)
    key(e, "session")
    create_session_emit(e, self.session)
    field_string(e, "retain", cron_retain_to_wire(self.retain))
    key(e, "input")
    input_emit(e, self.input)
    field_string(e, "on_missed", cron_missed_policy_to_wire(self.on_missed))
    field_string(e, "overlap", cron_overlap_to_wire(self.overlap))
    field_bool(e, "delete_after_run", self.delete_after_run)
    object_end(e)
}

// Verify annotated field bounds.
cron_job_spec_validate :: proc(self: Cron_Job_Spec) -> Validation_Error {
    if n, ok := self.name.?; ok {
        enforce_bounded(128, n) or_return
    }

    create_session_validate(self.session) or_return

    return input_validate(self.input)
}

// Deep-copy into `allocator`.
cron_job_spec_clone :: proc(self: Cron_Job_Spec, allocator := context.allocator) -> Cron_Job_Spec {
    name: Maybe(string)

    if n, ok := self.name.?; ok {
        name = strings.clone(n, allocator)
    }

    return Cron_Job_Spec {
        name = name,
        schedule = cron_schedule_clone(self.schedule, allocator),
        session = create_session_clone(self.session, allocator),
        retain = self.retain,
        input = input_clone(self.input, allocator),
        on_missed = self.on_missed,
        overlap = self.overlap,
        delete_after_run = self.delete_after_run,
    }
}

// A cron job record. Non-owning.
Cron_Job :: struct {
    // @fixed 16
    // Job id.
    id:                Job_Id,

    // Job spec at last write.
    spec:              Cron_Job_Spec,

    // Whether fires are active.
    enabled:           bool,

    // Creation epoch ms.
    created_at_ms:     u64,

    // @required-nullable
    // Next scheduled fire epoch ms; null when paused or done.
    next_run_ms:       Maybe(u64),

    // @required-nullable
    // Last fire epoch ms; null when none yet.
    last_run_ms:       Maybe(u64),

    // @required-nullable
    // Id of the session produced by the last fire.
    last_session_id:   Maybe(Session_Id),

    // @required-nullable
    // Outcome of the last fire.
    last_outcome:      Maybe(Cron_Run_Outcome),

    // Total successful fires since creation.
    run_count:         u64,

    // Total dispatch failures since creation.
    dispatch_failures: u64,
}

// Write a Cron_Job object; `next_run_ms`, `last_run_ms`, `last_session_id`, and
// `last_outcome` are always present, null when absent.
cron_job_emit :: proc(e: ^Emitter, self: Cron_Job) {
    object_begin(e)
    field_id(e, "id", ([16]u8)(self.id))
    key(e, "spec")
    cron_job_spec_emit(e, self.spec)
    field_bool(e, "enabled", self.enabled)
    field_u64(e, "created_at_ms", self.created_at_ms)
    field_required_null_u64(e, "next_run_ms", self.next_run_ms)
    field_required_null_u64(e, "last_run_ms", self.last_run_ms)
    key(e, "last_session_id")

    if sid, ok := self.last_session_id.?; ok {
        val_id(e, ([16]u8)(sid))
    } else {
        val_null(e)
    }

    key(e, "last_outcome")

    if oc, ok := self.last_outcome.?; ok {
        val_string(e, cron_run_outcome_to_wire(oc))
    } else {
        val_null(e)
    }

    field_u64(e, "run_count", self.run_count)
    field_u64(e, "dispatch_failures", self.dispatch_failures)
    object_end(e)
}

// Verify annotated field bounds.
cron_job_validate :: proc(self: Cron_Job) -> Validation_Error {
    enforce_id(([16]u8)(self.id)) or_return

    if sid, ok := self.last_session_id.?; ok {
        enforce_id(([16]u8)(sid)) or_return
    }

    return cron_job_spec_validate(self.spec)
}

// Deep-copy into `allocator`.
cron_job_clone :: proc(self: Cron_Job, allocator := context.allocator) -> Cron_Job {
    return Cron_Job {
        id = self.id,
        spec = cron_job_spec_clone(self.spec, allocator),
        enabled = self.enabled,
        created_at_ms = self.created_at_ms,
        next_run_ms = self.next_run_ms,
        last_run_ms = self.last_run_ms,
        last_session_id = self.last_session_id,
        last_outcome = self.last_outcome,
        run_count = self.run_count,
        dispatch_failures = self.dispatch_failures,
    }
}

// Decode internally-tagged cron schedule straight from the token stream.
cron_schedule_from_reader :: proc(d: ^Decoder) -> (sched: Cron_Schedule, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "every":
        interval_ms: u64
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "interval_ms":
                interval_ms = dec_u64(d) or_return
                have = true

            case "expr", "utc_offset_minutes", "at_ms", "delay_ms":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Cron_Schedule_Every{interval_ms = interval_ms}, .None

    case "cron":
        expr: string
        utc: i64

        Field :: enum {
            Expr,
            Utc,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "expr":
                expr = dec_string(d) or_return
                seen += {.Expr}

            case "utc_offset_minutes":
                utc = dec_i64(d) or_return
                seen += {.Utc}

            case "interval_ms", "at_ms", "delay_ms":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Expr, .Utc} {
            return nil, .Mismatched_Payload
        }

        return Cron_Schedule_Cron{expr = expr, utc_offset_minutes = utc}, .None

    case "at":
        at_ms: u64
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "at_ms":
                at_ms = dec_u64(d) or_return
                have = true

            case "interval_ms", "expr", "utc_offset_minutes", "delay_ms":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Cron_Schedule_At{at_ms = at_ms}, .None

    case "after":
        delay_ms: u64
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "delay_ms":
                delay_ms = dec_u64(d) or_return
                have = true

            case "interval_ms", "expr", "utc_offset_minutes", "at_ms":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Cron_Schedule_After{delay_ms = delay_ms}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a Cron_Job_Spec straight from the token stream.
cron_job_spec_from_reader :: proc(d: ^Decoder) -> (spec: Cron_Job_Spec, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sched,
        Sess,
        Retain,
        Input,
        Missed,
        Overlap,
        Del,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            spec.name = dec_string(d) or_return

        case "schedule":
            spec.schedule = cron_schedule_from_reader(d) or_return
            seen += {.Sched}

        case "session":
            spec.session = create_session_from_reader(d) or_return
            seen += {.Sess}

        case "retain":
            spec.retain = dec_enum(d, cron_retain_wire) or_return
            seen += {.Retain}

        case "input":
            spec.input = input_from_reader(d) or_return
            seen += {.Input}

        case "on_missed":
            spec.on_missed = dec_enum(d, cron_missed_policy_wire) or_return
            seen += {.Missed}

        case "overlap":
            spec.overlap = dec_enum(d, cron_overlap_wire) or_return
            seen += {.Overlap}

        case "delete_after_run":
            spec.delete_after_run = dec_bool(d) or_return
            seen += {.Del}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sched, .Sess, .Retain, .Input, .Missed, .Overlap, .Del} {
        return {}, .Mismatched_Payload
    }

    return spec, .None
}

// Decode a Cron_Job straight from the token stream.
cron_job_from_reader :: proc(d: ^Decoder) -> (out: Cron_Job, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Spec,
        Enabled,
        Created,
        Next,
        Last_Run,
        Last_Sess,
        Last_Out,
        Count,
        Disp,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            out.id = Job_Id(dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "spec":
            out.spec = cron_job_spec_from_reader(d) or_return
            seen += {.Spec}

        case "enabled":
            out.enabled = dec_bool(d) or_return
            seen += {.Enabled}

        case "created_at_ms":
            out.created_at_ms = dec_u64(d) or_return
            seen += {.Created}

        case "next_run_ms":
            seen += {.Next}

            if !dec_is_null(d) {
                out.next_run_ms = dec_u64(d) or_return
            }

        case "last_run_ms":
            seen += {.Last_Run}

            if !dec_is_null(d) {
                out.last_run_ms = dec_u64(d) or_return
            }

        case "last_session_id":
            seen += {.Last_Sess}

            if !dec_is_null(d) {
                out.last_session_id = Session_Id(dec_fixed(d, 16) or_return)
            }

        case "last_outcome":
            seen += {.Last_Out}

            if !dec_is_null(d) {
                out.last_outcome = dec_enum(d, cron_run_outcome_wire) or_return
            }

        case "run_count":
            out.run_count = dec_u64(d) or_return
            seen += {.Count}

        case "dispatch_failures":
            out.dispatch_failures = dec_u64(d) or_return
            seen += {.Disp}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Spec, .Enabled, .Created, .Next, .Last_Run, .Last_Sess, .Last_Out, .Count, .Disp} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Decode a Cron_Patch straight from the token stream.
cron_patch_from_reader :: proc(d: ^Decoder) -> (patch: Cron_Patch, err: Validation_Error) {
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            patch.name = dec_string(d) or_return

        case "schedule":
            patch.schedule = cron_schedule_from_reader(d) or_return

        case "session":
            patch.session = create_session_from_reader(d) or_return

        case "retain":
            patch.retain = dec_enum(d, cron_retain_wire) or_return

        case "input":
            patch.input = input_from_reader(d) or_return

        case "on_missed":
            patch.on_missed = dec_enum(d, cron_missed_policy_wire) or_return

        case "overlap":
            patch.overlap = dec_enum(d, cron_overlap_wire) or_return

        case "delete_after_run":
            patch.delete_after_run = dec_bool(d) or_return

        case "enabled":
            patch.enabled = dec_bool(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    return patch, .None
}

// Decode cron.create params straight from the token stream.
cron_create_params_from_reader :: proc(d: ^Decoder) -> (params: Cron_Create_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "spec":
            params.spec = cron_job_spec_from_reader(d) or_return
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

// Decode cron.patch params straight from the token stream.
cron_patch_params_from_reader :: proc(d: ^Decoder) -> (params: Cron_Patch_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Patch,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "job_id":
            params.job_id = Job_Id(dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "patch":
            params.patch = cron_patch_from_reader(d) or_return
            seen += {.Patch}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Patch} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a cron job reference straight from the token stream.
cron_job_ref_from_reader :: proc(d: ^Decoder) -> (params: Cron_Job_Ref, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "job_id":
            params.job_id = Job_Id(dec_fixed(d, 16) or_return)
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

// Decode cron.list params straight from the token stream.
cron_list_params_from_reader :: proc(d: ^Decoder) -> (params: Cron_List_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
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

// Decode a cron.list result straight from the token stream.
cron_list_result_from_reader :: proc(d: ^Decoder) -> (result: Cron_List_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Jobs,
        Next,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "revision":
            result.revision = Cron_Revision(dec_u64(d) or_return)
            seen += {.Rev}

        case "jobs":
            result.jobs = dec_array(d, cron_job_from_reader) or_return
            seen += {.Jobs}

        case "next_cursor":
            seen += {.Next}

            if !dec_is_null(d) {
                result.next_cursor = dec_string(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Jobs, .Next} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode a cron.run_now result straight from the token stream.
cron_run_now_result_from_reader :: proc(d: ^Decoder) -> (result: Cron_Run_Now_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Run,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            result.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "run_id":
            result.run_id = Run_Id(dec_u64(d) or_return)
            seen += {.Run}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Run} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}
