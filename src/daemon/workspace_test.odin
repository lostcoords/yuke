package daemon

import "core:fmt"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"

import "libs:offload"
import "src:client"
import "src:wire"

test_overlong_name :: proc() -> string {
    b := strings.builder_make(context.temp_allocator)
    for _ in 0 ..< 90 {
        strings.write_string(&b, "あ")
    }

    return strings.to_string(b)
}

check_describe_non_git :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    _, has_git := result.git.?
    testing.expect(t, !has_git, "a plain directory has no git info")

    canonical, cerr := os.get_absolute_path(o.dir, context.temp_allocator)
    testing.expect(t, cerr == nil, "the temp dir canonicalizes")
    testing.expect_value(t, result.workspace.root, canonical)
    testing.expect_value(t, result.workspace.id, workspace_id(canonical))
    testing.expect_value(t, result.workspace.title, os.base(canonical))
    testing.expect(t, result.last_modified_ms > 0, "mtime is populated")
    _, has_model := result.last_used_model.?
    testing.expect(t, !has_model, "no store means no last_used_model")

    return true
}

@(test)
test_daemon_workspace_describe_non_git :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-describe-nongit")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_non_git,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_describe_git :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    git, has_git := result.git.?
    if !testing.expect(t, has_git, "a directory with a .git is a repo") {
        return true
    }

    testing.expect_value(t, git.branch, "feature-x")
    testing.expect(t, !git.dirty, "dirty is not detected without the git binary")

    return true
}

@(test)
test_daemon_workspace_describe_git :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-describe-git")
    defer os.remove_all(dir)

    git_dir, _ := os.join_path({dir, ".git"}, context.temp_allocator)
    os.make_directory_all(git_dir)
    head, _ := os.join_path({git_dir, "HEAD"}, context.temp_allocator)
    _ = os.write_entire_file(head, "ref: refs/heads/feature-x\n")

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_git,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_describe_invalid_utf8_branch :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed with a non-UTF-8 branch") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    git, has_git := result.git.?
    if !testing.expect(t, has_git, "a directory with a .git is a repo") {
        return true
    }

    // A `.git/HEAD` ref whose branch component is not valid UTF-8 degrades to the same
    // empty branch as a detached or unreadable HEAD; it never rides an invalid frame.
    testing.expect_value(t, git.branch, "")

    return true
}

// Regression for invalid UTF-8 in filesystem bytes: a `.git/HEAD` whose branch is not
// valid UTF-8 must not produce a TEXT frame the WebSocket peer would reject; the
// branch comes back empty.
@(test)
test_daemon_workspace_describe_invalid_utf8_branch :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-describe-badbranch")
    defer os.remove_all(dir)

    git_dir, _ := os.join_path({dir, ".git"}, context.temp_allocator)
    os.make_directory_all(git_dir)
    head, _ := os.join_path({git_dir, "HEAD"}, context.temp_allocator)

    head_bytes := make([dynamic]u8, context.temp_allocator)
    append(&head_bytes, ..transmute([]u8)string("ref: refs/heads/"))
    append(&head_bytes, 0xFF, 0xFE)
    append(&head_bytes, '\n')
    _ = os.write_entire_file(head, head_bytes[:])

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_invalid_utf8_branch,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_describe_missing :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    e, is_err := resp.(wire.Response_Error)
    if !testing.expect(t, is_err, "a missing path is an error response") {
        return true
    }

    testing.expect_value(t, e.error.code, wire.Error_Code.Bad_Request)

    return true
}

@(test)
test_daemon_workspace_describe_missing_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = "/no/such/path/yuke-odin-xyz"},
        check = check_describe_missing,
    }
    run_handler(t, &obs)
}

check_describe_overlong_basename :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "describe should succeed even with an over-bound basename") {
        return true
    }

    result, is_desc := ok.result.(wire.Workspace_Describe_Result)
    if !testing.expect(t, is_desc, "result is a describe result") {
        return true
    }

    testing.expect(t, len(result.workspace.title) <= 256, "the title is clamped to the wire bound")
    testing.expect(t, utf8.valid_string(result.workspace.title), "a clamped title is still valid UTF-8")

    return true
}

// Regression for the daemon abort fixed by clamping `Workspace.title`: a directory
// whose basename exceeds the 256-byte wire bound (but is a legal APFS name) must not
// crash `describe` when it builds the result frame.
@(test)
test_daemon_workspace_describe_overlong_basename :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    parent := test_make_dir("yuke-odin-describe-overlong")
    defer os.remove_all(parent)

    dir, _ := os.join_path({parent, test_overlong_name()}, context.temp_allocator)
    if merr := os.make_directory_all(dir); merr != nil {
        fmt.printfln("skipping: filesystem rejected an overlong-basename directory: %v", merr)
        return
    }
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Describe,
        params = wire.Workspace_Describe_Params{path = dir},
        check = check_describe_overlong_basename,
        dir = dir,
    }
    run_handler(t, &obs)
}

// Populate a browse fixture: subdirectories `alpha`, `beta`, and `repo` (a git repo),
// plus a plain file that must be omitted from the listing.
test_make_browse_dir :: proc(name: string) -> string {
    dir := test_make_dir(name)

    for sub in ([]string{"alpha", "beta", "repo"}) {
        p, _ := os.join_path({dir, sub}, context.temp_allocator)
        os.make_directory_all(p)
    }

    repo_git, _ := os.join_path({dir, "repo", ".git"}, context.temp_allocator)
    os.make_directory_all(repo_git)
    file, _ := os.join_path({dir, "zeta.txt"}, context.temp_allocator)
    _ = os.write_entire_file(file, "x")

    return dir
}

check_browse_listing :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    if testing.expect_value(t, len(result.entries), 3) {
        // Directories only, `.git` and files omitted, sorted case-insensitively.
        testing.expect_value(t, result.entries[0].name, "alpha")
        testing.expect_value(t, result.entries[1].name, "beta")
        testing.expect_value(t, result.entries[2].name, "repo")
        testing.expect(t, result.entries[2].is_git_repo, "repo carries a .git")
        testing.expect(t, !result.entries[0].is_git_repo, "alpha carries no .git")
    }

    _, has_parent := result.parent.?
    testing.expect(t, has_parent, "a temp dir has a parent")
    _, has_cursor := result.next_cursor.?
    testing.expect(t, !has_cursor, "a single full page has a null next_cursor")

    return true
}

@(test)
test_daemon_workspace_browse_lists_directories :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-list")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir},
        check = check_browse_listing,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_paginated :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    if o.page == 0 {
        testing.expect_value(t, len(result.entries), 2)

        cursor, has := result.next_cursor.?
        if !testing.expect(t, has, "a 3-entry dir paged by 2 has a next_cursor") {
            return true
        }
        testing.expect_value(t, cursor, "beta")

        // The cursor is borrowed for this callback only; `client_send_request` copies
        // it into the outbound frame synchronously, so it is safe to forward here.
        o.page = 1
        client.client_send_request(
            c,
            .Workspace_Browse,
            wire.Workspace_Browse_Params{path = o.dir, limit = 2, cursor = cursor},
            handler_on_response,
        )

        return false
    }

    testing.expect_value(t, len(result.entries), 1)
    _, has := result.next_cursor.?
    testing.expect(t, !has, "the final page has a null next_cursor")

    return true
}

@(test)
test_daemon_workspace_browse_paginates :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-page")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir, limit = 2},
        check = check_browse_paginated,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_missing :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    e, is_err := resp.(wire.Response_Error)
    if !testing.expect(t, is_err, "a missing path is an error response") {
        return true
    }

    testing.expect_value(t, e.error.code, wire.Error_Code.Bad_Request)

    return true
}

@(test)
test_daemon_workspace_browse_missing_path :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = "/no/such/path/yuke-odin-xyz"},
        check = check_browse_missing,
    }
    run_handler(t, &obs)
}

check_browse_name_cursor :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "an opaque name cursor is accepted") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    if testing.expect_value(t, len(result.entries), 1) {
        testing.expect_value(t, result.entries[0].name, "repo")
    }
    _, has_cursor := result.next_cursor.?
    testing.expect(t, !has_cursor, "the name boundary reaches the final page")

    return true
}

@(test)
test_daemon_workspace_browse_uses_name_cursor :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-name-cursor")
    defer os.remove_all(dir)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir, cursor = "beta"},
        check = check_browse_name_cursor,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_skips_overlong_name :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed even with an unrepresentable entry name") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    found_normal := false
    for entry in result.entries {
        testing.expect(t, len(entry.name) <= 256, "every emitted entry name is within the wire bound")
        if entry.name == "normal" {
            found_normal = true
        }
    }

    testing.expect(t, found_normal, "the normal sibling entry is still listed")

    return true
}

// Regression for the daemon abort fixed by skipping over-bound directory entries: a
// subdirectory whose name exceeds the 256-byte wire bound (but is a legal APFS name)
// must not crash `browse` when it builds the result frame; it is simply omitted.
@(test)
test_daemon_workspace_browse_skips_overlong_name :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-browse-overlong")
    defer os.remove_all(dir)

    normal, _ := os.join_path({dir, "normal"}, context.temp_allocator)
    os.make_directory_all(normal)

    overlong, _ := os.join_path({dir, test_overlong_name()}, context.temp_allocator)
    if merr := os.make_directory_all(overlong); merr != nil {
        fmt.printfln("skipping: filesystem rejected an overlong-name directory: %v", merr)
        return
    }

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir},
        check = check_browse_skips_overlong_name,
        dir = dir,
    }
    run_handler(t, &obs)
}

check_browse_skips_non_utf8_name :: proc(c: ^client.Client, resp: wire.Response, o: ^Handler_Obs) -> bool {
    t := o.t
    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(t, is_ok, "browse should succeed even with a non-UTF-8 entry name") {
        return true
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(t, is_browse, "result is a browse result") {
        return true
    }

    found_normal := false
    for entry in result.entries {
        testing.expect(t, utf8.valid_string(entry.name), "every emitted entry name is valid UTF-8")
        testing.expect(t, utf8.valid_string(entry.path), "every emitted entry path is valid UTF-8")
        if entry.name == "normal" {
            found_normal = true
        }
    }

    testing.expect(t, found_normal, "the normal sibling entry is still listed")

    return true
}

// Regression for invalid UTF-8 in filesystem bytes: a subdirectory whose name is not
// valid UTF-8 cannot ride a WebSocket TEXT frame, so `browse` omits it rather than
// emitting a frame the peer would reject; the valid sibling is still listed.
@(test)
test_daemon_workspace_browse_skips_non_utf8_name :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_dir("yuke-odin-browse-nonutf8")
    defer os.remove_all(dir)

    normal, _ := os.join_path({dir, "normal"}, context.temp_allocator)
    os.make_directory_all(normal)

    // A subdirectory name built from raw bytes (0xFF 0xFE) that are not valid UTF-8.
    // Some filesystems reject such names, in which case the case skips like the
    // overlong-name fixture.
    name := [?]u8{0xFF, 0xFE}
    path_bytes := make([]u8, len(dir) + 1 + len(name), context.temp_allocator)
    copy(path_bytes[:], transmute([]u8)dir)
    path_bytes[len(dir)] = '/'
    copy(path_bytes[len(dir) + 1:], name[:])
    invalid := string(path_bytes)
    if merr := os.make_directory_all(invalid); merr != nil {
        fmt.printfln("skipping: filesystem rejected a non-UTF-8 directory name: %v", merr)
        return
    }
    defer os.remove_all(invalid)

    obs := Handler_Obs {
        method = .Workspace_Browse,
        params = wire.Workspace_Browse_Params{path = dir},
        check = check_browse_skips_non_utf8_name,
        dir = dir,
    }
    run_handler(t, &obs)
}

// --- Offloaded workspace work outliving its request and its connection --------

// Observations for the two-browses-in-flight test. Both requests are sent from the same
// `on_ready` turn, so the daemon has two filesystem passes outstanding on one connection.
Concurrent_Obs :: struct {
    // The active testing context, so checks can assert from inside the callback.
    t:         ^testing.T,

    // Fixture with three subdirectories; the first request browses it.
    dir:       string,

    // Fixture with one subdirectory; the second request browses it.
    other:     string,

    // Entry counts keyed by the browsed path, so each response is matched to its own
    // request rather than to arrival order.
    counts:    map[string]int,

    // Responses delivered.
    answered:  int,

    // Terminal callback fired.
    done:      bool,

    // Either a terminal callback or the harness timeout fired.
    wait_done: bool,

    // The harness timeout fired before both responses arrived.
    timed_out: bool,
}

concurrent_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Concurrent_Obs)(c.user_data)
    client.client_send_request(
        c,
        .Workspace_Browse,
        wire.Workspace_Browse_Params{path = o.dir},
        concurrent_on_response,
    )
    client.client_send_request(
        c,
        .Workspace_Browse,
        wire.Workspace_Browse_Params{path = o.other},
        concurrent_on_response,
    )
}

concurrent_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    o := (^Concurrent_Obs)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !testing.expect(o.t, has_response, "browse request should receive a response") {
        client.client_close(c)
        return
    }

    resp := answered.response
    o.answered += 1

    ok, is_ok := resp.(wire.Response_Ok)
    if !testing.expect(o.t, is_ok, "both browses should succeed") {
        client.client_close(c)
        return
    }

    result, is_browse := ok.result.(wire.Workspace_Browse_Result)
    if !testing.expect(o.t, is_browse, "result is a browse result") {
        client.client_close(c)
        return
    }

    // The result path is borrowed for this callback only, so each response is recorded
    // under the matching fixture string the test owns for the whole run. A path matching
    // neither fixture is a failure in its own right: silently attributing it to one of
    // them would report a wrong entry count somewhere else instead.
    switch result.path {
    case o.dir:
        o.counts[o.dir] = len(result.entries)

    case o.other:
        o.counts[o.other] = len(result.entries)

    case:
        testing.expectf(o.t, false, "browse answered for an unrequested path %q", result.path)
        client.client_close(c)

        return
    }

    if o.answered == 2 {
        client.client_close(c)
    }
}

concurrent_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Concurrent_Obs)(c.user_data)
    o.done = true
    o.wait_done = true
}

concurrent_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Concurrent_Obs)(c.user_data)
    o.done = true
    o.wait_done = true
}

concurrent_on_timeout :: proc(_: ^nbio.Operation, o: ^Concurrent_Obs) {
    o.timed_out = true
    o.wait_done = true
}

// Two `workspace.browse` requests in flight on one connection are both answered, each
// against its own directory. Responses correlate by request id, so the offloaded passes
// may complete in either order.
@(test)
test_daemon_workspace_browse_two_in_flight :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-concurrent-a")
    defer os.remove_all(dir)

    other := test_make_dir("yuke-odin-browse-concurrent-b")
    defer os.remove_all(other)
    only, _ := os.join_path({other, "solo"}, context.temp_allocator)
    os.make_directory_all(only)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0})
    testing.expect_value(t, derr, Error.None)

    // Browse answers with the canonical path, so the correlation keys must be canonical
    // too: on macOS the temp fixtures live under `/var/...`, which resolves to
    // `/private/var/...` and would never match the raw fixture string.
    canonical_dir, dir_err := os.get_absolute_path(dir, context.temp_allocator)
    testing.expect(t, dir_err == nil, "the browse fixture canonicalizes")
    canonical_other, other_err := os.get_absolute_path(other, context.temp_allocator)
    testing.expect(t, other_err == nil, "the second fixture canonicalizes")

    obs := Concurrent_Obs {
        t     = t,
        dir   = canonical_dir,
        other = canonical_other,
    }
    obs.counts = make(map[string]int, 4, context.temp_allocator)

    c: client.Client
    transport := client.ws_create(
        loop,
        {host = "127.0.0.1", port = bound_port(&d), path = "/ws"},
        context.temp_allocator,
    )

    cerr := client.client_open(
        &c,
        transport,
        "yuke-test",
        "0.1.0",
        client.Client_Callbacks {
            on_ready = concurrent_on_ready,
            on_close = concurrent_on_close,
            on_error = concurrent_on_error,
        },
        &obs,
        context.temp_allocator,
    )
    testing.expect_value(t, cerr, client.Protocol_Error.None)

    timeout_op := nbio.timeout_poly(2 * time.Second, &obs, concurrent_on_timeout, loop)
    nbio.run_until(&obs.wait_done)

    if !obs.timed_out {
        nbio.remove(timeout_op)
    } else {
        shutdown(&d)
        nbio.run_until(&obs.done)
    }

    testing.expect(t, !obs.timed_out, "both browses should answer before the harness timeout")
    testing.expect_value(t, obs.answered, 2)
    testing.expect_value(t, obs.counts[canonical_dir], 3)
    testing.expect_value(t, obs.counts[canonical_other], 1)

    client.client_destroy(&c)
    test_teardown(&d)
}

// Observations for the browse-then-close soak: the connection is closed in the same turn
// the request is sent, so the filesystem pass is still on a worker when its `Conn` goes.
Detach_Obs :: struct {
    // Directory the browse targets.
    dir:  string,

    // Terminal callback fired.
    done: bool,
}

detach_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    o := (^Detach_Obs)(c.user_data)
    client.client_send_request(c, .Workspace_Browse, wire.Workspace_Browse_Params{path = o.dir}, detach_on_response)
    client.client_close(c)
}

// The connection is closed in the same turn the request was sent, so this may never run.
detach_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
}

detach_on_close :: proc(c: ^client.Client, code: client.Close_Code) {
    o := (^Detach_Obs)(c.user_data)
    o.done = true
}

detach_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    o := (^Detach_Obs)(c.user_data)
    o.done = true
}

// A `workspace.browse` whose connection closes while its filesystem pass is still on a
// worker must neither crash nor leak: the completion resolves a ticket rather than a
// `^Conn`, finds nobody to answer, and frees the job. Repeated so the close lands both
// before and after the pass finishes.
@(test)
test_daemon_workspace_browse_close_during_pass_no_leak :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    dir := test_make_browse_dir("yuke-odin-browse-detach")
    defer os.remove_all(dir)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    d: Daemon
    derr := start(&d, loop, {host = "127.0.0.1", port = 0}, tracked)
    testing.expect_value(t, derr, Error.None)

    port := bound_port(&d)
    ITERATIONS :: 32

    for i in 0 ..< ITERATIONS {
        obs := Detach_Obs {
            dir = dir,
        }

        c: client.Client
        transport := client.ws_create(loop, {host = "127.0.0.1", port = port, path = "/ws"}, tracked)

        cerr := client.client_open(
            &c,
            transport,
            "yuke-test",
            "0.1.0",
            client.Client_Callbacks {
                on_ready = detach_on_ready,
                on_close = detach_on_close,
                on_error = detach_on_error,
            },
            &obs,
            tracked,
        )
        testing.expect_value(t, cerr, client.Protocol_Error.None)

        nbio.run_until(&obs.done)
        client.client_destroy(&c)

        // Let the daemon-side release and any finished pass land before the next cycle,
        // so completions interleave with fresh accepts instead of batching at teardown.
        for _ in 0 ..< 64 {
            if len(d.ws_server.conns) == 0 && offload.pool_outstanding(&d.workers) == 0 {
                break
            }

            nbio.tick(time.Millisecond)
        }

        testing.expectf(t, obs.done, "cycle %d should reach a terminal callback", i)
    }

    test_teardown(&d)

    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}
