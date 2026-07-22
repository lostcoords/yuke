package wire

import "core:strings"

// Daemon-known workspace directory. Non-owning.
Workspace :: struct {
    // Derived workspace id. @fixed 16
    id:    Workspace_Id,

    // Canonical absolute path. @unbounded
    root:  string,

    // Display title. @bounded 256
    title: string,
}

// Write a Workspace object.
workspace_emit :: proc(e: ^Emitter, self: Workspace) {
    object_begin(e)
    field_id(e, "id", ([16]u8)(self.id))
    field_string(e, "root", self.root)
    field_string(e, "title", self.title)
    object_end(e)
}

// Verify annotated field bounds.
workspace_validate :: proc(self: Workspace) -> Validation_Error {
    enforce_id(([16]u8)(self.id)) or_return

    return enforce_bounded(256, self.title)
}

// Deep-copy into `allocator`.
workspace_clone :: proc(self: Workspace, allocator := context.allocator) -> Workspace {
    return Workspace {
        id = self.id,
        root = strings.clone(self.root, allocator),
        title = strings.clone(self.title, allocator),
    }
}

// Git status for a workspace root, when it is a repo. Non-owning.
Git_Info :: struct {
    // @bounded 256
    branch: string,

    // Whether the working tree has uncommitted changes.
    dirty:  bool,
}

// Write a Git_Info object.
git_info_emit :: proc(e: ^Emitter, self: Git_Info) {
    object_begin(e)
    field_string(e, "branch", self.branch)
    field_bool(e, "dirty", self.dirty)
    object_end(e)
}

// Verify annotated field bounds.
git_info_validate :: proc(self: Git_Info) -> Validation_Error {
    return enforce_bounded(256, self.branch)
}

// workspace.describe input. Non-owning.
Workspace_Describe_Params :: struct {
    // @unbounded
    path: string,
}

// Write workspace.describe params.
workspace_describe_params_emit :: proc(e: ^Emitter, self: Workspace_Describe_Params) {
    object_begin(e)
    field_string(e, "path", self.path)
    object_end(e)
}

// workspace.describe result. Non-owning.
Workspace_Describe_Result :: struct {
    // Resolved workspace.
    workspace:        Workspace,

    // Git status; null when the root is not a repo.
    git:              Maybe(Git_Info),

    // Last filesystem modification epoch ms.
    last_modified_ms: u64,

    // Last model used in this workspace; null if never run.
    last_used_model:  Maybe(string),
}

// Write a workspace.describe result. `git` and `last_used_model` are always
// emitted, null when absent.
workspace_describe_result_emit :: proc(e: ^Emitter, self: Workspace_Describe_Result) {
    object_begin(e)
    key(e, "workspace")
    workspace_emit(e, self.workspace)
    key(e, "git")

    if git, ok := self.git.?; ok {
        git_info_emit(e, git)
    } else {
        val_null(e)
    }

    field_u64(e, "last_modified_ms", self.last_modified_ms)
    field_required_null_string(e, "last_used_model", self.last_used_model)
    object_end(e)
}

// Verify annotated field bounds.
workspace_describe_result_validate :: proc(self: Workspace_Describe_Result) -> Validation_Error {
    workspace_validate(self.workspace) or_return

    if git, ok := self.git.?; ok {
        git_info_validate(git) or_return
    }
    // `last_used_model` is @unbounded — no length limit.
    return .None
}

// workspace.browse input. Non-owning.
Workspace_Browse_Params :: struct {
    // @unbounded
    path:   Maybe(string),

    // Page size; omitted means daemon default.
    limit:  Maybe(u64),

    // Opaque continuation within the same directory. @bounded 256
    cursor: Maybe(string),
}

// Write workspace.browse params, omitting absent fields.
workspace_browse_params_emit :: proc(e: ^Emitter, self: Workspace_Browse_Params) {
    object_begin(e)
    field_string_opt(e, "path", self.path)

    if limit, ok := self.limit.?; ok {
        field_u64(e, "limit", limit)
    }

    field_string_opt(e, "cursor", self.cursor)
    object_end(e)
}

// Verify the page and cursor bounds.
workspace_browse_params_validate :: proc(self: Workspace_Browse_Params) -> Validation_Error {
    if limit, ok := self.limit.?; ok {
        if limit == 0 || limit > u64(LIMITS.max_workspace_browse_page_size) {
            return .Out_Of_Range
        }
    }

    if cursor, ok := self.cursor.?; ok {
        return enforce_bounded(LIMITS.max_workspace_browse_cursor_bytes, cursor)
    }

    return .None
}

// A single filesystem entry in a browse listing. Non-owning.
Dir_Entry :: struct {
    // @bounded 256
    name:        string,

    // @unbounded
    path:        string,

    // Whether this directory is itself a git repo.
    is_git_repo: bool,
}

// Write a Dir_Entry object.
dir_entry_emit :: proc(e: ^Emitter, self: Dir_Entry) {
    object_begin(e)
    field_string(e, "name", self.name)
    field_string(e, "path", self.path)
    field_bool(e, "is_git_repo", self.is_git_repo)
    object_end(e)
}

// Verify annotated field bounds.
dir_entry_validate :: proc(self: Dir_Entry) -> Validation_Error {
    return enforce_bounded(256, self.name)
}

// workspace.browse result. Non-owning.
Workspace_Browse_Result :: struct {
    // @unbounded
    path:        string,

    // Parent directory path; null at the filesystem root.
    parent:      Maybe(string),

    // Directory contents.
    entries:     []Dir_Entry,

    // Opaque continuation; required null on the final page. @bounded 256
    next_cursor: Maybe(string),
}

// Write a workspace.browse result. `parent` and `next_cursor` are always
// emitted, null when absent.
workspace_browse_result_emit :: proc(e: ^Emitter, self: Workspace_Browse_Result) {
    object_begin(e)
    field_string(e, "path", self.path)
    field_required_null_string(e, "parent", self.parent)
    key(e, "entries")
    array_begin(e)
    for entry in self.entries {
        elem(e)
        dir_entry_emit(e, entry)
    }

    array_end(e)
    field_required_null_string(e, "next_cursor", self.next_cursor)
    object_end(e)
}

// Verify annotated field bounds.
workspace_browse_result_validate :: proc(self: Workspace_Browse_Result) -> Validation_Error {
    if len(self.entries) > LIMITS.max_workspace_browse_page_size {
        return .Overflow
    }

    for entry in self.entries {
        dir_entry_validate(entry) or_return
    }

    if cursor, ok := self.next_cursor.?; ok {
        return enforce_bounded(LIMITS.max_workspace_browse_cursor_bytes, cursor)
    }

    return .None
}

// workspace.remove input.
Workspace_Remove_Params :: struct {
    // Workspace to remove.
    workspace_id: Workspace_Id,
}

// Write workspace.remove params.
workspace_remove_params_emit :: proc(e: ^Emitter, self: Workspace_Remove_Params) {
    object_begin(e)
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    object_end(e)
}

// workspace.remove result. Non-owning.
Workspace_Remove_Result :: struct {
    // Cron jobs that referenced the removed workspace.
    related_job_ids: []Job_Id,
}

// Write a workspace.remove result.
workspace_remove_result_emit :: proc(e: ^Emitter, self: Workspace_Remove_Result) {
    object_begin(e)
    key(e, "related_job_ids")
    array_begin(e)
    for jid in self.related_job_ids {
        elem(e)
        val_id(e, ([16]u8)(jid))
    }

    array_end(e)
    object_end(e)
}

// Verify annotated field bounds.
workspace_remove_result_validate :: proc(self: Workspace_Remove_Result) -> Validation_Error {
    if len(self.related_job_ids) > LIMITS.max_cron_jobs {
        return .Overflow
    }

    for jid in self.related_job_ids {
        enforce_id(([16]u8)(jid)) or_return
    }

    return .None
}

// Where a skill definition was loaded from.
Skill_Scope :: enum {
    Project,
    Personal,
}

// Skill_Scope <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
skill_scope_wire := [Skill_Scope]string {
    .Project  = "project",
    .Personal = "personal",
}

// Wire string for a skill scope.
skill_scope_to_wire :: proc(s: Skill_Scope) -> string {
    return skill_scope_wire[s]
}

// Skill scope for a wire string; ok is false for an unknown scope.
skill_scope_from_wire :: proc(s: string) -> (Skill_Scope, bool) {
    return enum_from_wire(skill_scope_wire, s)
}

// Discovered skill metadata. Non-owning.
Skill_Info :: struct {
    // @bounded 64
    name:          string,

    // @bounded 512
    description:   string,

    // Project- or personal-scoped.
    scope:         Skill_Scope,

    // @bounded 128
    argument_hint: string,
}

// Write a Skill_Info object.
skill_info_emit :: proc(e: ^Emitter, self: Skill_Info) {
    object_begin(e)
    field_string(e, "name", self.name)
    field_string(e, "description", self.description)
    field_string(e, "scope", skill_scope_to_wire(self.scope))
    field_string(e, "argument_hint", self.argument_hint)
    object_end(e)
}

// Verify annotated field bounds.
skill_info_validate :: proc(self: Skill_Info) -> Validation_Error {
    enforce_bounded(64, self.name) or_return
    enforce_bounded(512, self.description) or_return

    return enforce_bounded(128, self.argument_hint)
}

// workspace.skills.list input.
Skill_List_Params :: struct {
    // Workspace to list skills for.
    workspace_id: Workspace_Id,
}

// Write workspace.skills.list params.
skill_list_params_emit :: proc(e: ^Emitter, self: Skill_List_Params) {
    object_begin(e)
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    object_end(e)
}

// workspace.skills.list result. Non-owning.
Skill_List_Result :: struct {
    // Discovered skills. At most 1024.
    skills: []Skill_Info,
}

// Write a workspace.skills.list result.
skill_list_result_emit :: proc(e: ^Emitter, self: Skill_List_Result) {
    object_begin(e)
    key(e, "skills")
    array_begin(e)
    for skill in self.skills {
        elem(e)
        skill_info_emit(e, skill)
    }

    array_end(e)
    object_end(e)
}

// Verify annotated field bounds.
skill_list_result_validate :: proc(self: Skill_List_Result) -> Validation_Error {
    if len(self.skills) > LIMITS.max_skills {
        return .Overflow
    }

    for skill in self.skills {
        skill_info_validate(skill) or_return
    }

    return .None
}

// --- streaming decoders ---

// Decode a Workspace straight from the token stream.
workspace_from_reader :: proc(d: ^Decoder) -> (ws: Workspace, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Root,
        Title,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            ws.id = Workspace_Id(dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "root":
            ws.root = dec_string(d) or_return
            seen += {.Root}

        case "title":
            ws.title = dec_string(d) or_return
            seen += {.Title}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Root, .Title} {
        return {}, .Mismatched_Payload
    }

    return ws, .None
}

// Decode a Git_Info straight from the token stream.
git_info_from_reader :: proc(d: ^Decoder) -> (git: Git_Info, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Branch,
        Dirty,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "branch":
            git.branch = dec_string(d) or_return
            seen += {.Branch}

        case "dirty":
            git.dirty = dec_bool(d) or_return
            seen += {.Dirty}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Branch, .Dirty} {
        return {}, .Mismatched_Payload
    }

    return git, .None
}

// Decode a Dir_Entry straight from the token stream.
dir_entry_from_reader :: proc(d: ^Decoder) -> (entry: Dir_Entry, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Path,
        Git,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            entry.name = dec_string(d) or_return
            seen += {.Name}

        case "path":
            entry.path = dec_string(d) or_return
            seen += {.Path}

        case "is_git_repo":
            entry.is_git_repo = dec_bool(d) or_return
            seen += {.Git}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Path, .Git} {
        return {}, .Mismatched_Payload
    }

    return entry, .None
}

// Decode a Skill_Info straight from the token stream.
skill_info_from_reader :: proc(d: ^Decoder) -> (info: Skill_Info, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Desc,
        Scope,
        Hint,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            info.name = dec_string(d) or_return
            seen += {.Name}

        case "description":
            info.description = dec_string(d) or_return
            seen += {.Desc}

        case "scope":
            info.scope = dec_enum(d, skill_scope_wire) or_return
            seen += {.Scope}

        case "argument_hint":
            info.argument_hint = dec_string(d) or_return
            seen += {.Hint}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Desc, .Scope, .Hint} {
        return {}, .Mismatched_Payload
    }

    return info, .None
}

// Decode a workspace.describe result straight from the token stream.
workspace_describe_result_from_reader :: proc(
    d: ^Decoder,
) -> (
    result: Workspace_Describe_Result,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return

    Field :: enum {
        Ws,
        Git,
        Mod,
        Model,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace":
            result.workspace = workspace_from_reader(d) or_return
            seen += {.Ws}

        case "git":
            seen += {.Git}

            if !dec_is_null(d) {
                result.git = git_info_from_reader(d) or_return
            }

        case "last_modified_ms":
            result.last_modified_ms = dec_u64(d) or_return
            seen += {.Mod}

        case "last_used_model":
            seen += {.Model}

            if !dec_is_null(d) {
                result.last_used_model = dec_string(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Ws, .Git, .Mod, .Model} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode workspace.browse params straight from the token stream.
workspace_browse_params_from_reader :: proc(d: ^Decoder) -> (params: Workspace_Browse_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            params.path = dec_string(d) or_return

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

// Decode a workspace.browse result straight from the token stream.
workspace_browse_result_from_reader :: proc(d: ^Decoder) -> (result: Workspace_Browse_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Path,
        Parent,
        Entries,
        Next,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            result.path = dec_string(d) or_return
            seen += {.Path}

        case "parent":
            seen += {.Parent}

            if !dec_is_null(d) {
                result.parent = dec_string(d) or_return
            }

        case "entries":
            result.entries = dec_array(d, dir_entry_from_reader) or_return
            seen += {.Entries}

        case "next_cursor":
            seen += {.Next}

            if !dec_is_null(d) {
                result.next_cursor = dec_string(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Path, .Parent, .Entries, .Next} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode workspace.remove params straight from the token stream.
workspace_remove_params_from_reader :: proc(d: ^Decoder) -> (params: Workspace_Remove_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            params.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
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

// Decode a workspace.remove result straight from the token stream.
workspace_remove_result_from_reader :: proc(d: ^Decoder) -> (result: Workspace_Remove_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "related_job_ids":
            result.related_job_ids = dec_array(d, _job_id_from_reader) or_return
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

@(private)
_job_id_from_reader :: proc(d: ^Decoder) -> (out: Job_Id, err: Validation_Error) {
    out = Job_Id(dec_fixed(d, 16) or_return)

    return out, .None
}

// Decode workspace.skills params straight from the token stream.
skill_list_params_from_reader :: proc(d: ^Decoder) -> (params: Skill_List_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            params.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
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

// Decode a workspace.skills result straight from the token stream.
skill_list_result_from_reader :: proc(d: ^Decoder) -> (result: Skill_List_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "skills":
            result.skills = dec_array(d, skill_info_from_reader) or_return
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

// Decode workspace.describe params straight from the token stream.
workspace_describe_params_from_reader :: proc(
    d: ^Decoder,
) -> (
    params: Workspace_Describe_Params,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            params.path = dec_string(d) or_return
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
