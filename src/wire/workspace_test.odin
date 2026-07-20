package wire

import "core:testing"

@(test)
test_workspace_roundtrip :: proc(t: ^testing.T) {
    input := `{"id":"0123456789abcdef","root":"/repo","title":"repo"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    ws, derr := workspace_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    id := ([16]u8)(ws.id)
    testing.expect_value(t, string(id[:]), "0123456789abcdef")
    testing.expect_value(t, ws.root, "/repo")
    testing.expect_value(t, ws.title, "repo")
    testing.expect(t, workspace_validate(ws) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_emit(&e, ws)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_describe_result_roundtrip :: proc(t: ^testing.T) {
    input := `{"workspace":{"id":"0123456789abcdef","root":"/r","title":"r"},"git":{"branch":"main","dirty":false},"last_modified_ms":1,"last_used_model":"gpt-4"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    result, derr := workspace_describe_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    git, has_git := result.git.?
    testing.expect(t, has_git, "git should be present")
    testing.expect_value(t, git.branch, "main")
    testing.expect_value(t, git.dirty, false)
    model, has_model := result.last_used_model.?
    testing.expect(t, has_model, "last_used_model should be present")
    testing.expect_value(t, model, "gpt-4")
    testing.expect(t, workspace_describe_result_validate(result) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_describe_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_describe_result_null_git_and_model :: proc(t: ^testing.T) {
    input := `{"workspace":{"id":"0123456789abcdef","root":"/r","title":"r"},"git":null,"last_modified_ms":1,"last_used_model":null}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    result, derr := workspace_describe_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, has_git := result.git.?
    testing.expect(t, !has_git, "git should be absent")
    _, has_model := result.last_used_model.?
    testing.expect(t, !has_model, "last_used_model should be absent")
    testing.expect(t, workspace_describe_result_validate(result) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_describe_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_browse_params_roundtrip :: proc(t: ^testing.T) {
    input := `{"path":"/home","limit":50,"cursor":"abc"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    params, derr := workspace_browse_params_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    limit, has_limit := params.limit.?
    testing.expect(t, has_limit, "limit should be present")
    testing.expect_value(t, limit, u64(50))
    testing.expect(t, workspace_browse_params_validate(params) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_browse_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_browse_params_rejects_zero_limit :: proc(t: ^testing.T) {
    params := Workspace_Browse_Params {
        limit = u64(0),
    }
    testing.expect(t, workspace_browse_params_validate(params) == .Out_Of_Range, "zero limit must be out of range")
}

@(test)
test_workspace_browse_result_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"path":"/home","parent":"/","entries":[{"name":"src","path":"/home/src","is_git_repo":true}],"next_cursor":"xyz"}`
    v := decoder_init(input)

    result, derr := workspace_browse_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, result.path, "/home")
    parent, has_parent := result.parent.?
    testing.expect(t, has_parent, "parent should be present")
    testing.expect_value(t, parent, "/")
    testing.expect_value(t, len(result.entries), 1)
    testing.expect_value(t, result.entries[0].name, "src")
    testing.expect_value(t, result.entries[0].is_git_repo, true)
    cursor, has_cursor := result.next_cursor.?
    testing.expect(t, has_cursor, "next_cursor should be present")
    testing.expect_value(t, cursor, "xyz")
    testing.expect(t, workspace_browse_result_validate(result) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_browse_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_browse_result_null_next_cursor :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"path":"/r","parent":null,"entries":[],"next_cursor":null}`
    v := decoder_init(input)

    result, derr := workspace_browse_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, has_parent := result.parent.?
    testing.expect(t, !has_parent, "parent should be absent")
    _, has_cursor := result.next_cursor.?
    testing.expect(t, !has_cursor, "next_cursor should be absent")
    testing.expect_value(t, len(result.entries), 0)
    testing.expect(t, workspace_browse_result_validate(result) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_browse_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_remove_result_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"related_job_ids":["0123456789abcdef","fedcba9876543210"]}`
    v := decoder_init(input)

    result, derr := workspace_remove_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, len(result.related_job_ids), 2)
    first := ([16]u8)(result.related_job_ids[0])
    testing.expect_value(t, string(first[:]), "0123456789abcdef")
    testing.expect(t, workspace_remove_result_validate(result) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    workspace_remove_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_skill_list_result_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"skills":[{"name":"deploy","description":"Deploy the app","scope":"project","argument_hint":"env"}]}`
    v := decoder_init(input)

    result, derr := skill_list_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, len(result.skills), 1)
    testing.expect_value(t, result.skills[0].name, "deploy")
    testing.expect_value(t, result.skills[0].scope, Skill_Scope.Project)
    testing.expect_value(t, result.skills[0].argument_hint, "env")
    testing.expect(t, skill_list_result_validate(result) == .None, "validate should pass")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    skill_list_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_skill_list_params_roundtrip :: proc(t: ^testing.T) {
    input := `{"workspace_id":"0123456789abcdef"}`
    v := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    params, derr := skill_list_params_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    wid := ([16]u8)(params.workspace_id)
    testing.expect_value(t, string(wid[:]), "0123456789abcdef")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    skill_list_params_emit(&e, params)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_workspace_browse_result_rejects_missing_next_cursor :: proc(t: ^testing.T) {
    // The final-page marker is `"next_cursor":null`, not an absent key: a browse
    // result must always carry the field.
    input := `{"path":"/home","parent":"/","entries":[{"name":"src","path":"/home/src","is_git_repo":true}]}`
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    v := decoder_init(input, context.temp_allocator)
    _, derr := workspace_browse_result_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "missing next_cursor must be rejected")
}
