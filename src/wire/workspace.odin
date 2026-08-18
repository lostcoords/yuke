package wire
import "libs:json"

import "core:strings"

// Daemon-known workspace directory. Non-owning.
Workspace :: struct {
    // @fixed 16
    // Derived workspace id.
    id:    Workspace_Id,

    // @unbounded
    // Canonical absolute path.
    root:  string,

    // @bounded 256
    // Display title.
    title: string,
}

// Write a Workspace object.
workspace_emit :: proc(e: ^json.Emitter, self: Workspace) {
    json.object_begin(e)
    json.field_id(e, "id", ([16]u8)(self.id))
    json.field_string(e, "root", self.root)
    json.field_string(e, "title", self.title)
    json.object_end(e)
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
    //
    branch: string,

    // Whether the working tree has uncommitted changes.
    dirty:  bool,
}

// Write a Git_Info object.
git_info_emit :: proc(e: ^json.Emitter, self: Git_Info) {
    json.object_begin(e)
    json.field_string(e, "branch", self.branch)
    json.field_bool(e, "dirty", self.dirty)
    json.object_end(e)
}

// Verify annotated field bounds.
git_info_validate :: proc(self: Git_Info) -> Validation_Error {
    return enforce_bounded(256, self.branch)
}

// workspace.describe input. Non-owning.
Workspace_Describe_Params :: struct {
    // @unbounded
    //
    path: string,
}

// Write workspace.describe params.
workspace_describe_params_emit :: proc(e: ^json.Emitter, self: Workspace_Describe_Params) {
    json.object_begin(e)
    json.field_string(e, "path", self.path)
    json.object_end(e)
}

// workspace.describe result. Non-owning.
Workspace_Describe_Result :: struct {
    // Resolved workspace.
    workspace:        Workspace,

    // @required-nullable
    // Git status; null when the root is not a repo.
    git:              Maybe(Git_Info),

    // Last filesystem modification epoch ms.
    last_modified_ms: u64,

    // @required-nullable
    // @unbounded
    // Last model used in this workspace; null if never run.
    last_used_model:  Maybe(string),
}

// Write a workspace.describe result. `git` and `last_used_model` are always
// emitted, null when absent.
workspace_describe_result_emit :: proc(e: ^json.Emitter, self: Workspace_Describe_Result) {
    json.object_begin(e)
    json.key(e, "workspace")
    workspace_emit(e, self.workspace)
    json.key(e, "git")

    if git, ok := self.git.?; ok {
        git_info_emit(e, git)
    } else {
        json.val_null(e)
    }

    json.field_u64(e, "last_modified_ms", self.last_modified_ms)
    json.field_required_null_string(e, "last_used_model", self.last_used_model)
    json.object_end(e)
}

// Verify annotated field bounds.
workspace_describe_result_validate :: proc(self: Workspace_Describe_Result) -> Validation_Error {
    workspace_validate(self.workspace) or_return

    if git, ok := self.git.?; ok do git_info_validate(git) or_return
    // `last_used_model` is @unbounded — no length limit.
    return .None
}

// workspace.browse input. Non-owning.
Workspace_Browse_Params :: struct {
    // @unbounded
    //
    path:   Maybe(string),

    // Page size; omitted means daemon default.
    limit:  Maybe(u64),

    // @bounded LIMITS.max_workspace_browse_cursor_bytes
    // Opaque continuation within the same directory.
    cursor: Maybe(string),
}

// Write workspace.browse params, omitting absent fields.
workspace_browse_params_emit :: proc(e: ^json.Emitter, self: Workspace_Browse_Params) {
    json.object_begin(e)
    json.field_string_opt(e, "path", self.path)

    if limit, ok := self.limit.?; ok do json.field_u64(e, "limit", limit)

    json.field_string_opt(e, "cursor", self.cursor)
    json.object_end(e)
}

// Verify the page and cursor bounds.
workspace_browse_params_validate :: proc(self: Workspace_Browse_Params) -> Validation_Error {
    if limit, ok := self.limit.?; ok {
        if limit == 0 || limit > u64(LIMITS.max_workspace_browse_page_size) do return .Out_Of_Range
    }

    if cursor, ok := self.cursor.?; ok do return enforce_bounded(LIMITS.max_workspace_browse_cursor_bytes, cursor)

    return .None
}

// A single filesystem entry in a browse listing. Non-owning.
Dir_Entry :: struct {
    // @bounded 256
    //
    name:        string,

    // @unbounded
    //
    path:        string,

    // Whether this directory is itself a git repo.
    is_git_repo: bool,
}

// Write a Dir_Entry object.
dir_entry_emit :: proc(e: ^json.Emitter, self: Dir_Entry) {
    json.object_begin(e)
    json.field_string(e, "name", self.name)
    json.field_string(e, "path", self.path)
    json.field_bool(e, "is_git_repo", self.is_git_repo)
    json.object_end(e)
}

// Verify annotated field bounds.
dir_entry_validate :: proc(self: Dir_Entry) -> Validation_Error {
    return enforce_bounded(256, self.name)
}

// workspace.browse result. Non-owning.
Workspace_Browse_Result :: struct {
    // @unbounded
    //
    path:        string,

    // @required-nullable
    // @unbounded
    // Parent directory path; null at the filesystem root.
    parent:      Maybe(string),

    // @bounded LIMITS.max_workspace_browse_page_size
    // Directory contents.
    entries:     []Dir_Entry,

    // @required-nullable
    // @bounded LIMITS.max_workspace_browse_cursor_bytes
    // Opaque continuation; required null on the final page.
    next_cursor: Maybe(string),
}

// Write a workspace.browse result. `parent` and `next_cursor` are always
// emitted, null when absent.
workspace_browse_result_emit :: proc(e: ^json.Emitter, self: Workspace_Browse_Result) {
    json.object_begin(e)
    json.field_string(e, "path", self.path)
    json.field_required_null_string(e, "parent", self.parent)
    json.key(e, "entries")
    json.array_begin(e)
    for entry in self.entries {
        json.elem(e)
        dir_entry_emit(e, entry)
    }

    json.array_end(e)
    json.field_required_null_string(e, "next_cursor", self.next_cursor)
    json.object_end(e)
}

// Verify annotated field bounds.
workspace_browse_result_validate :: proc(self: Workspace_Browse_Result) -> Validation_Error {
    if len(self.entries) > LIMITS.max_workspace_browse_page_size do return .Overflow

    for entry in self.entries {
        dir_entry_validate(entry) or_return
    }

    if cursor, ok := self.next_cursor.?; ok do return enforce_bounded(LIMITS.max_workspace_browse_cursor_bytes, cursor)

    return .None
}

// Params naming a workspace and nothing else. Shared by `workspace.remove`,
// `workspace.skills`, and `permission.rules`; split it the moment one of them needs a
// field of its own.
Workspace_Ref :: struct {
    // @fixed 16
    // Workspace the request targets.
    workspace_id: Workspace_Id,
}

// Write a workspace reference.
workspace_ref_emit :: proc(e: ^json.Emitter, self: Workspace_Ref) {
    json.object_begin(e)
    json.field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    json.object_end(e)
}

// Verify the target id.
workspace_ref_validate :: proc(self: Workspace_Ref) -> Validation_Error {
    return enforce_id(([16]u8)(self.workspace_id))
}

// workspace.remove result. Non-owning.
Workspace_Remove_Result :: struct {
    // @bounded LIMITS.max_cron_jobs
    // Cron jobs that referenced the removed workspace.
    related_job_ids: []Job_Id,
}

// Write a workspace.remove result.
workspace_remove_result_emit :: proc(e: ^json.Emitter, self: Workspace_Remove_Result) {
    json.object_begin(e)
    json.key(e, "related_job_ids")
    json.array_begin(e)
    for jid in self.related_job_ids {
        json.elem(e)
        json.val_id(e, ([16]u8)(jid))
    }

    json.array_end(e)
    json.object_end(e)
}

// Verify annotated field bounds.
workspace_remove_result_validate :: proc(self: Workspace_Remove_Result) -> Validation_Error {
    if len(self.related_job_ids) > LIMITS.max_cron_jobs do return .Overflow

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
    return json.enum_from_wire(skill_scope_wire, s)
}

// Discovered skill metadata. Non-owning.
Skill_Info :: struct {
    // @bounded 64
    //
    name:          string,

    // @bounded 512
    //
    description:   string,

    // Project- or personal-scoped.
    scope:         Skill_Scope,

    // @bounded 128
    //
    argument_hint: string,
}

// Write a Skill_Info object.
skill_info_emit :: proc(e: ^json.Emitter, self: Skill_Info) {
    json.object_begin(e)
    json.field_string(e, "name", self.name)
    json.field_string(e, "description", self.description)
    json.field_string(e, "scope", skill_scope_to_wire(self.scope))
    json.field_string(e, "argument_hint", self.argument_hint)
    json.object_end(e)
}

// Verify annotated field bounds.
skill_info_validate :: proc(self: Skill_Info) -> Validation_Error {
    enforce_bounded(64, self.name) or_return
    enforce_bounded(512, self.description) or_return

    return enforce_bounded(128, self.argument_hint)
}

// workspace.skills.list result. Non-owning.
Workspace_Skills_Result :: struct {
    // @bounded LIMITS.max_skills
    // Discovered skills.
    skills: []Skill_Info,
}

// Write a workspace.skills.list result.
workspace_skills_result_emit :: proc(e: ^json.Emitter, self: Workspace_Skills_Result) {
    json.object_begin(e)
    json.key(e, "skills")
    json.array_begin(e)
    for skill in self.skills {
        json.elem(e)
        skill_info_emit(e, skill)
    }

    json.array_end(e)
    json.object_end(e)
}

// Verify annotated field bounds.
workspace_skills_result_validate :: proc(self: Workspace_Skills_Result) -> Validation_Error {
    if len(self.skills) > LIMITS.max_skills do return .Overflow

    for skill in self.skills {
        skill_info_validate(skill) or_return
    }

    return .None
}

// Decode a Workspace straight from the token stream.
workspace_from_reader :: proc(d: ^json.Decoder) -> (ws: Workspace, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Root,
        Title,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            ws.id = Workspace_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "root":
            ws.root = json.dec_string(d) or_return
            seen += {.Root}

        case "title":
            ws.title = json.dec_string(d) or_return
            seen += {.Title}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Root, .Title} do return {}, .Mismatched_Payload

    return ws, .None
}

// Decode a Git_Info straight from the token stream.
git_info_from_reader :: proc(d: ^json.Decoder) -> (git: Git_Info, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Branch,
        Dirty,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "branch":
            git.branch = json.dec_string(d) or_return
            seen += {.Branch}

        case "dirty":
            git.dirty = json.dec_bool(d) or_return
            seen += {.Dirty}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Branch, .Dirty} do return {}, .Mismatched_Payload

    return git, .None
}

// Decode a Dir_Entry straight from the token stream.
dir_entry_from_reader :: proc(d: ^json.Decoder) -> (entry: Dir_Entry, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Path,
        Git,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            entry.name = json.dec_string(d) or_return
            seen += {.Name}

        case "path":
            entry.path = json.dec_string(d) or_return
            seen += {.Path}

        case "is_git_repo":
            entry.is_git_repo = json.dec_bool(d) or_return
            seen += {.Git}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Path, .Git} do return {}, .Mismatched_Payload

    return entry, .None
}

// Decode a Skill_Info straight from the token stream.
skill_info_from_reader :: proc(d: ^json.Decoder) -> (info: Skill_Info, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Desc,
        Scope,
        Hint,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            info.name = json.dec_string(d) or_return
            seen += {.Name}

        case "description":
            info.description = json.dec_string(d) or_return
            seen += {.Desc}

        case "scope":
            info.scope = json.dec_enum(d, skill_scope_wire) or_return
            seen += {.Scope}

        case "argument_hint":
            info.argument_hint = json.dec_string(d) or_return
            seen += {.Hint}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Desc, .Scope, .Hint} do return {}, .Mismatched_Payload

    return info, .None
}

// Decode a workspace.describe result straight from the token stream.
workspace_describe_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Workspace_Describe_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Ws,
        Git,
        Mod,
        Model,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "workspace":
            result.workspace = workspace_from_reader(d) or_return
            seen += {.Ws}

        case "git":
            seen += {.Git}

            if !json.dec_is_null(d) do result.git = git_info_from_reader(d) or_return

        case "last_modified_ms":
            result.last_modified_ms = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Mod}

        case "last_used_model":
            seen += {.Model}

            if !json.dec_is_null(d) do result.last_used_model = json.dec_string(d) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Ws, .Git, .Mod, .Model} do return {}, .Mismatched_Payload

    return result, .None
}

// Decode workspace.browse params straight from the token stream.
workspace_browse_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Workspace_Browse_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            params.path = json.dec_string(d) or_return

        case "limit":
            params.limit = json.dec_u64(d, MAX_WIRE_INTEGER) or_return

        case "cursor":
            params.cursor = json.dec_string(d) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    return params, .None
}

// Decode a workspace.browse result straight from the token stream.
workspace_browse_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Workspace_Browse_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Path,
        Parent,
        Entries,
        Next,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            result.path = json.dec_string(d) or_return
            seen += {.Path}

        case "parent":
            seen += {.Parent}

            if !json.dec_is_null(d) do result.parent = json.dec_string(d) or_return

        case "entries":
            result.entries = json.dec_array(d, dir_entry_from_reader) or_return
            seen += {.Entries}

        case "next_cursor":
            seen += {.Next}

            if !json.dec_is_null(d) do result.next_cursor = json.dec_string(d) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Path, .Parent, .Entries, .Next} do return {}, .Mismatched_Payload

    return result, .None
}

// Decode a workspace reference straight from the token stream.
workspace_ref_from_reader :: proc(d: ^json.Decoder) -> (params: Workspace_Ref, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            params.workspace_id = Workspace_Id(json.dec_fixed(d, 16) or_return)
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return params, .None
}

// Decode a workspace.remove result straight from the token stream.
workspace_remove_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Workspace_Remove_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "related_job_ids":
            result.related_job_ids = json.dec_array(d, _job_id_from_reader) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return result, .None
}

@(private)
_job_id_from_reader :: proc(d: ^json.Decoder) -> (out: Job_Id, err: json.Decode_Error) {
    out = Job_Id(json.dec_fixed(d, 16) or_return)

    return out, .None
}

// Decode a workspace.skills result straight from the token stream.
workspace_skills_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Workspace_Skills_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "skills":
            result.skills = json.dec_array(d, skill_info_from_reader) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return result, .None
}

// Decode workspace.describe params straight from the token stream.
workspace_describe_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Workspace_Describe_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "path":
            params.path = json.dec_string(d) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return params, .None
}
