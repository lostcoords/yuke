package wire

// Closed enum of RPC method names. Source of truth for the method set.
Method_Name :: enum {
    // Negotiate the protocol version and exchange identity. Must be the first
    // request on a connection, and is the only one accepted before Ready.
    Initialize,

    // Read a bounded daemon-ordered session-index page.
    Session_List,

    // Create a new session.
    Session_Create,

    // Patch session settings.
    Session_Patch,

    // Remove a session and its data.
    Session_Remove,

    // Fork a session from another session's transcript.
    Session_Fork,

    // Request manual compaction of the transcript context.
    Session_Compact,

    // Truncate the transcript at a user message.
    Session_Rewind,

    // Send user input to a session.
    Session_Send_Input,

    // Cancel a queued input that has not started.
    Session_Cancel_Input,

    // Cancel the active run, optionally clearing queue and pending compaction.
    Session_Cancel_Run,

    // Resync a session with a windowed transcript snapshot.
    Session_Resync,

    // Read older committed history beyond the resync window.
    Session_History,

    // Answer a pending permission request.
    Permission_Decide,

    // Fetch a session's run config and system prompt by config_rev.
    Session_Config,

    // Replace the subscription set.
    Subscription_Set,

    // Fetch the model catalog, with optional `since_rev`.
    Catalog_List,

    // Re-read provider and credential configuration from disk.
    Catalog_Refresh,

    // Describe an arbitrary path as a workspace.
    Workspace_Describe,

    // List directories on the daemon host.
    Workspace_Browse,

    // Remove a workspace and its sessions.
    Workspace_Remove,

    // List skills available in a workspace.
    Workspace_Skills,

    // List remembered permission rules for a workspace.
    Permission_Rules,

    // Forget a remembered permission rule.
    Permission_Forget,

    // Create a cron job.
    Cron_Create,

    // Patch a cron job.
    Cron_Patch,

    // Remove a cron job.
    Cron_Remove,

    // List cron jobs.
    Cron_List,

    // Fire a cron job immediately.
    Cron_Run_Now,
}

// Method_Name <-> wire string, indexed by the enum so a missing mapping is
// visible. The dotted wire names live only here.
@(rodata)
method_name_wire := [Method_Name]string {
    .Initialize           = "initialize",
    .Session_List         = "session.list",
    .Session_Create       = "session.create",
    .Session_Patch        = "session.patch",
    .Session_Remove       = "session.remove",
    .Session_Fork         = "session.fork",
    .Session_Compact      = "session.compact",
    .Session_Rewind       = "session.rewind",
    .Session_Send_Input   = "session.send_input",
    .Session_Cancel_Input = "session.cancel_input",
    .Session_Cancel_Run   = "session.cancel_run",
    .Session_Resync       = "session.resync",
    .Session_History      = "session.history",
    .Permission_Decide    = "permission.decide",
    .Session_Config       = "session.config",
    .Subscription_Set     = "subscription.set",
    .Catalog_List         = "catalog.list",
    .Catalog_Refresh      = "catalog.refresh",
    .Workspace_Describe   = "workspace.describe",
    .Workspace_Browse     = "workspace.browse",
    .Workspace_Remove     = "workspace.remove",
    .Workspace_Skills     = "workspace.skills",
    .Permission_Rules     = "permission.rules",
    .Permission_Forget    = "permission.forget",
    .Cron_Create          = "cron.create",
    .Cron_Patch           = "cron.patch",
    .Cron_Remove          = "cron.remove",
    .Cron_List            = "cron.list",
    .Cron_Run_Now         = "cron.run_now",
}

// Wire string for a method name.
method_name_to_wire :: proc(m: Method_Name) -> string {
    return method_name_wire[m]
}

// Parse a method name from its wire string; ok is false for an unknown method.
method_name_from_wire :: proc(s: string) -> (Method_Name, bool) {
    return enum_from_wire(method_name_wire, s)
}

// Empty params/result object (`{}`) for methods whose registry entry uses `{}`.
Empty_Params :: struct {}
// Empty result payload.
Empty_Result :: struct {}

// Write an empty params object.
empty_params_emit :: proc(e: ^Emitter) {
    object_begin(e)
    object_end(e)
}

// Write an empty result object.
empty_result_emit :: proc(e: ^Emitter) {
    object_begin(e)
    object_end(e)
}

// Result of `session.create` and `session.fork`.
Session_Result :: struct {
    // Resulting session.
    session: Session,
}

// Write a session result.
session_result_emit :: proc(e: ^Emitter, self: Session_Result) {
    object_begin(e)
    key(e, "session")
    session_emit(e, self.session)
    object_end(e)
}

// Verify annotated field bounds.
session_result_validate :: proc(self: Session_Result) -> Validation_Error {
    return session_validate(self.session)
}

// Params for `session.patch`.
Session_Patch_Params :: struct {
    // Session to patch.
    session_id: Session_Id,

    // Patch to apply.
    patch:      Session_Patch,
}

// Write session.patch params.
session_patch_params_emit :: proc(e: ^Emitter, self: Session_Patch_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    key(e, "patch")
    session_patch_emit(e, self.patch)
    object_end(e)
}

// Verify annotated field bounds.
session_patch_params_validate :: proc(self: Session_Patch_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return session_patch_validate(self.patch)
}

// Result of `session.patch`.
Session_Patch_Result :: struct {
    // Patched session, carrying the resulting config_rev and permission mode.
    session: Session,
}

// Write a session.patch result.
session_patch_result_emit :: proc(e: ^Emitter, self: Session_Patch_Result) {
    object_begin(e)
    key(e, "session")
    session_emit(e, self.session)
    object_end(e)
}

// Verify annotated field bounds.
session_patch_result_validate :: proc(self: Session_Patch_Result) -> Validation_Error {
    return session_validate(self.session)
}

// Params for `session.remove`.
Session_Remove_Params :: struct {
    // Session to remove.
    session_id:       Session_Id,

    // Recursively remove persistent child sessions.
    cascade_children: bool,
}

// Write session.remove params.
session_remove_params_emit :: proc(e: ^Emitter, self: Session_Remove_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_bool(e, "cascade_children", self.cascade_children)
    object_end(e)
}

// Verify annotated field bounds.
session_remove_params_validate :: proc(self: Session_Remove_Params) -> Validation_Error {
    return enforce_id(([16]u8)(self.session_id))
}

// Result of `cron.create` and `cron.patch`.
Cron_Job_Result :: struct {
    // The cron job.
    job: Cron_Job,
}

// Write a cron job result.
cron_job_result_emit :: proc(e: ^Emitter, self: Cron_Job_Result) {
    object_begin(e)
    key(e, "job")
    cron_job_emit(e, self.job)
    object_end(e)
}

// Verify annotated field bounds.
cron_job_result_validate :: proc(self: Cron_Job_Result) -> Validation_Error {
    return cron_job_validate(self.job)
}

// Runtime params payload tagged by the same enum as `Method_Name`.
Request_Params :: union {
    Initialize_Params,
    Session_List_Params,
    Create_Session,
    Session_Patch_Params,
    Session_Remove_Params,
    Fork_Params,
    Compact_Params,
    Rewind_Params,
    Send_Input_Params,
    Cancel_Input_Params,
    Cancel_Run_Params,
    Resync_Params,
    History_Params,
    Permission_Decide_Params,
    Config_Get_Params,
    Subscription_Set_Params,
    Catalog_List_Params,
    Empty_Params,
    Workspace_Describe_Params,
    Workspace_Browse_Params,
    Workspace_Remove_Params,
    Skill_List_Params,
    Permission_Rules_Params,
    Permission_Forget_Params,
    Cron_Create_Params,
    Cron_Patch_Params,
    Cron_Remove_Params,
    Cron_List_Params,
    Cron_Run_Now_Params,
}

// Runtime result payload tagged by the request method that produced it.
Response_Result :: union {
    Initialize_Result,
    Session_List_Result,
    Session_Result,
    Session_Patch_Result,
    Empty_Result,
    Compact_Result,
    Send_Input_Result,
    Cancel_Input_Result,
    Cancel_Run_Result,
    Resync_Result,
    History_Result,
    Config_Get_Result,
    Catalog_List_Result,
    Catalog_Refresh_Result,
    Workspace_Describe_Result,
    Workspace_Browse_Result,
    Workspace_Remove_Result,
    Skill_List_Result,
    Permission_Rules_Result,
    Cron_Job_Result,
    Cron_List_Result,
    Cron_Run_Now_Result,
}

// Serialize just the params object, not the method tag.
request_params_emit :: proc(e: ^Emitter, params: Request_Params) {
    switch p in params {
    case Initialize_Params:
        initialize_params_emit(e, p)

    case Session_List_Params:
        session_list_params_emit(e, p)

    case Create_Session:
        create_session_emit(e, p)

    case Session_Patch_Params:
        session_patch_params_emit(e, p)

    case Session_Remove_Params:
        session_remove_params_emit(e, p)

    case Fork_Params:
        fork_params_emit(e, p)

    case Compact_Params:
        compact_params_emit(e, p)

    case Rewind_Params:
        rewind_params_emit(e, p)

    case Send_Input_Params:
        send_input_params_emit(e, p)

    case Cancel_Input_Params:
        cancel_input_params_emit(e, p)

    case Cancel_Run_Params:
        cancel_run_params_emit(e, p)

    case Resync_Params:
        resync_params_emit(e, p)

    case History_Params:
        history_params_emit(e, p)

    case Permission_Decide_Params:
        permission_decide_params_emit(e, p)

    case Config_Get_Params:
        config_get_params_emit(e, p)

    case Subscription_Set_Params:
        subscription_set_params_emit(e, p)

    case Catalog_List_Params:
        catalog_list_params_emit(e, p)

    case Empty_Params:
        empty_params_emit(e)

    case Workspace_Describe_Params:
        workspace_describe_params_emit(e, p)

    case Workspace_Browse_Params:
        workspace_browse_params_emit(e, p)

    case Workspace_Remove_Params:
        workspace_remove_params_emit(e, p)

    case Skill_List_Params:
        skill_list_params_emit(e, p)

    case Permission_Rules_Params:
        permission_rules_params_emit(e, p)

    case Permission_Forget_Params:
        permission_forget_params_emit(e, p)

    case Cron_Create_Params:
        cron_create_params_emit(e, p)

    case Cron_Patch_Params:
        cron_patch_params_emit(e, p)

    case Cron_Remove_Params:
        cron_remove_params_emit(e, p)

    case Cron_List_Params:
        cron_list_params_emit(e, p)

    case Cron_Run_Now_Params:
        cron_run_now_params_emit(e, p)
    }
}

// Serialize just the result object, not the method tag.
response_result_emit :: proc(e: ^Emitter, result: Response_Result) {
    switch r in result {
    case Initialize_Result:
        initialize_result_emit(e, r)

    case Session_List_Result:
        session_list_result_emit(e, r)

    case Session_Result:
        session_result_emit(e, r)

    case Session_Patch_Result:
        session_patch_result_emit(e, r)

    case Empty_Result:
        empty_result_emit(e)

    case Compact_Result:
        compact_result_emit(e, r)

    case Send_Input_Result:
        send_input_result_emit(e, r)

    case Cancel_Input_Result:
        cancel_input_result_emit(e, r)

    case Cancel_Run_Result:
        cancel_run_result_emit(e, r)

    case Resync_Result:
        resync_result_emit(e, r)

    case History_Result:
        history_result_emit(e, r)

    case Config_Get_Result:
        config_get_result_emit(e, r)

    case Catalog_List_Result:
        catalog_list_result_emit(e, r)

    case Catalog_Refresh_Result:
        catalog_refresh_result_emit(e, r)

    case Workspace_Describe_Result:
        workspace_describe_result_emit(e, r)

    case Workspace_Browse_Result:
        workspace_browse_result_emit(e, r)

    case Workspace_Remove_Result:
        workspace_remove_result_emit(e, r)

    case Skill_List_Result:
        skill_list_result_emit(e, r)

    case Permission_Rules_Result:
        permission_rules_result_emit(e, r)

    case Cron_Job_Result:
        cron_job_result_emit(e, r)

    case Cron_List_Result:
        cron_list_result_emit(e, r)

    case Cron_Run_Now_Result:
        cron_run_now_result_emit(e, r)
    }
}

// Validate the active params variant, if it defines `validate`.
request_params_validate :: proc(params: Request_Params) -> Validation_Error {
    #partial switch p in params {
    case Initialize_Params:
        return initialize_params_validate(p)

    case Session_List_Params:
        return session_list_params_validate(p)

    case Create_Session:
        return create_session_validate(p)

    case Session_Patch_Params:
        return session_patch_params_validate(p)

    case Session_Remove_Params:
        return session_remove_params_validate(p)

    case Send_Input_Params:
        return send_input_params_validate(p)

    case Cancel_Input_Params:
        return cancel_input_params_validate(p)

    case Cancel_Run_Params:
        return cancel_run_params_validate(p)

    case Permission_Decide_Params:
        return permission_decide_params_validate(p)

    case Subscription_Set_Params:
        return subscription_set_params_validate(p)

    case Workspace_Browse_Params:
        return workspace_browse_params_validate(p)

    case Permission_Forget_Params:
        return permission_forget_params_validate(p)

    case Cron_Create_Params:
        return cron_create_params_validate(p)

    case Cron_Patch_Params:
        return cron_patch_params_validate(p)

    case Cron_Remove_Params:
        return cron_remove_params_validate(p)

    case Cron_List_Params:
        return cron_list_params_validate(p)

    case Cron_Run_Now_Params:
        return cron_run_now_params_validate(p)
    }

    return .None
}

// Validate the active result variant, if it defines `validate`.
response_result_validate :: proc(result: Response_Result) -> Validation_Error {
    #partial switch r in result {
    case Initialize_Result:
        return initialize_result_validate(r)

    case Session_List_Result:
        return session_list_result_validate(r)

    case Session_Result:
        return session_result_validate(r)

    case Session_Patch_Result:
        return session_patch_result_validate(r)

    case Resync_Result:
        return resync_result_validate(r)

    case History_Result:
        return history_result_validate(r)

    case Config_Get_Result:
        return config_get_result_validate(r)

    case Catalog_List_Result:
        return catalog_list_result_validate(r)

    case Catalog_Refresh_Result:
        return catalog_refresh_result_validate(r)

    case Workspace_Describe_Result:
        return workspace_describe_result_validate(r)

    case Workspace_Browse_Result:
        return workspace_browse_result_validate(r)

    case Workspace_Remove_Result:
        return workspace_remove_result_validate(r)

    case Skill_List_Result:
        return skill_list_result_validate(r)

    case Permission_Rules_Result:
        return permission_rules_result_validate(r)

    case Cron_Job_Result:
        return cron_job_result_validate(r)

    case Cron_List_Result:
        return cron_list_result_validate(r)

    case Cron_Run_Now_Result:
        return cron_run_now_result_validate(r)
    }

    return .None
}

// Whether this concrete params value is represented by omitting `params`.
params_are_default :: proc(params: Request_Params) -> bool {
    #partial switch p in params {
    case Session_List_Params:
        if _, is_all := p.scope.(Session_Scope_All); !is_all {
            return false
        }

        if _, is_top := p.population.(Session_Population_Top_Level); !is_top {
            return false
        }

        return p.view == .Active_Recent && p.limit == nil && p.cursor == nil

    case Catalog_List_Params:
        return p.since_rev == nil

    case Empty_Params:
        return true

    case Workspace_Browse_Params:
        return p.path == nil && p.limit == nil && p.cursor == nil

    case Cron_List_Params:
        return p.limit == nil && p.cursor == nil
    }

    return false
}

// Default params for methods that permit an omitted `params`, else nil.
default_params :: proc(method: Method_Name) -> Maybe(Request_Params) {
    params: Request_Params

    #partial switch method {
    case .Session_List:
        params = Session_List_Params {
            scope      = Session_Scope_All{},
            population = Session_Population_Top_Level{},
            view       = .Active_Recent,
        }

    case .Catalog_List:
        params = Catalog_List_Params{}

    case .Catalog_Refresh:
        params = Empty_Params{}

    case .Workspace_Browse:
        params = Workspace_Browse_Params{}

    case .Cron_List:
        params = Cron_List_Params{}

    case:
        return nil
    }

    return params
}

// --- streaming decoders ---

// Read an empty params object; extra fields are ignored.
empty_params_from_reader :: proc(d: ^Decoder) -> (out: Empty_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    for {
        _, done := dec_key(d) or_return
        if done do break
        dec_skip(d) or_return
    }

    return {}, .None
}

// Read an empty result object; extra fields are ignored.
empty_result_from_reader :: proc(d: ^Decoder) -> (out: Empty_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    for {
        _, done := dec_key(d) or_return
        if done do break
        dec_skip(d) or_return
    }

    return {}, .None
}

// Decode a session result straight from the token stream.
session_result_from_reader :: proc(d: ^Decoder) -> (out: Session_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session":
            out.session = session_from_reader(d) or_return
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

// Decode session.patch params straight from the token stream.
session_patch_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Patch_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Patch,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "patch":
            params.patch = session_patch_from_reader(d) or_return
            seen += {.Patch}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Patch} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a session.patch result straight from the token stream.
session_patch_result_from_reader :: proc(d: ^Decoder) -> (result: Session_Patch_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session":
            result.session = session_from_reader(d) or_return
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

// Decode session.remove params straight from the token stream.
session_remove_params_from_reader :: proc(d: ^Decoder) -> (params: Session_Remove_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            have = true

        case "cascade_children":
            params.cascade_children = dec_bool(d) or_return

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a cron job result straight from the token stream.
cron_job_result_from_reader :: proc(d: ^Decoder) -> (result: Cron_Job_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "job":
            result.job = cron_job_from_reader(d) or_return
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

// Decode typed request params for `method` straight from the token stream.
request_params_from_reader :: proc(
    method: Method_Name,
    d: ^Decoder,
) -> (
    params: Request_Params,
    err: Validation_Error,
) {
    switch method {
    case .Initialize:
        params = initialize_params_from_reader(d) or_return

    case .Session_List:
        params = session_list_params_from_reader(d) or_return

    case .Session_Create:
        params = create_session_from_reader(d) or_return

    case .Session_Patch:
        params = session_patch_params_from_reader(d) or_return

    case .Session_Remove:
        params = session_remove_params_from_reader(d) or_return

    case .Session_Fork:
        params = fork_params_from_reader(d) or_return

    case .Session_Compact:
        params = compact_params_from_reader(d) or_return

    case .Session_Rewind:
        params = rewind_params_from_reader(d) or_return

    case .Session_Send_Input:
        params = send_input_params_from_reader(d) or_return

    case .Session_Cancel_Input:
        params = cancel_input_params_from_reader(d) or_return

    case .Session_Cancel_Run:
        params = cancel_run_params_from_reader(d) or_return

    case .Session_Resync:
        params = resync_params_from_reader(d) or_return

    case .Session_History:
        params = history_params_from_reader(d) or_return

    case .Permission_Decide:
        params = permission_decide_params_from_reader(d) or_return

    case .Session_Config:
        params = config_get_params_from_reader(d) or_return

    case .Subscription_Set:
        params = subscription_set_params_from_reader(d) or_return

    case .Catalog_List:
        params = catalog_list_params_from_reader(d) or_return

    case .Catalog_Refresh:
        params = empty_params_from_reader(d) or_return

    case .Workspace_Describe:
        params = workspace_describe_params_from_reader(d) or_return

    case .Workspace_Browse:
        params = workspace_browse_params_from_reader(d) or_return

    case .Workspace_Remove:
        params = workspace_remove_params_from_reader(d) or_return

    case .Workspace_Skills:
        params = skill_list_params_from_reader(d) or_return

    case .Permission_Rules:
        params = permission_rules_params_from_reader(d) or_return

    case .Permission_Forget:
        params = permission_forget_params_from_reader(d) or_return

    case .Cron_Create:
        params = cron_create_params_from_reader(d) or_return

    case .Cron_Patch:
        params = cron_patch_params_from_reader(d) or_return

    case .Cron_Remove:
        params = cron_remove_params_from_reader(d) or_return

    case .Cron_List:
        params = cron_list_params_from_reader(d) or_return

    case .Cron_Run_Now:
        params = cron_run_now_params_from_reader(d) or_return
    }

    return
}

// Decode the typed result for `method` straight from the token stream.
response_result_from_reader :: proc(
    method: Method_Name,
    d: ^Decoder,
) -> (
    result: Response_Result,
    err: Validation_Error,
) {
    switch method {
    case .Initialize:
        result = initialize_result_from_reader(d) or_return

    case .Session_List:
        result = session_list_result_from_reader(d) or_return

    case .Session_Create:
        result = session_result_from_reader(d) or_return

    case .Session_Patch:
        result = session_patch_result_from_reader(d) or_return

    case .Session_Remove:
        result = empty_result_from_reader(d) or_return

    case .Session_Fork:
        result = session_result_from_reader(d) or_return

    case .Session_Compact:
        result = compact_result_from_reader(d) or_return

    case .Session_Rewind:
        result = empty_result_from_reader(d) or_return

    case .Session_Send_Input:
        result = send_input_result_from_reader(d) or_return

    case .Session_Cancel_Input:
        result = cancel_input_result_from_reader(d) or_return

    case .Session_Cancel_Run:
        result = cancel_run_result_from_reader(d) or_return

    case .Session_Resync:
        result = resync_result_from_reader(d) or_return

    case .Session_History:
        result = history_result_from_reader(d) or_return

    case .Permission_Decide:
        result = empty_result_from_reader(d) or_return

    case .Session_Config:
        result = config_get_result_from_reader(d) or_return

    case .Subscription_Set:
        result = empty_result_from_reader(d) or_return

    case .Catalog_List:
        result = catalog_list_result_from_reader(d) or_return

    case .Catalog_Refresh:
        result = catalog_refresh_result_from_reader(d) or_return

    case .Workspace_Describe:
        result = workspace_describe_result_from_reader(d) or_return

    case .Workspace_Browse:
        result = workspace_browse_result_from_reader(d) or_return

    case .Workspace_Remove:
        result = workspace_remove_result_from_reader(d) or_return

    case .Workspace_Skills:
        result = skill_list_result_from_reader(d) or_return

    case .Permission_Rules:
        result = permission_rules_result_from_reader(d) or_return

    case .Permission_Forget:
        result = empty_result_from_reader(d) or_return

    case .Cron_Create:
        result = cron_job_result_from_reader(d) or_return

    case .Cron_Patch:
        result = cron_job_result_from_reader(d) or_return

    case .Cron_Remove:
        result = empty_result_from_reader(d) or_return

    case .Cron_List:
        result = cron_list_result_from_reader(d) or_return

    case .Cron_Run_Now:
        result = cron_run_now_result_from_reader(d) or_return
    }

    return
}
