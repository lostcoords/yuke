package wire

import "core:strings"
import "core:testing"

// Sample catalog revision for tests.
sample_catalog_rev :: proc() -> Catalog_Rev {
    rev := "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    out: [64]u8
    for i in 0 ..< 64 {
        out[i] = rev[i]
    }

    return Catalog_Rev(out)
}

// Minimal valid Initialize_Result fixture for tests.
empty_hello :: proc() -> Initialize_Result {
    return Initialize_Result {
        protocol = PROTOCOL_VERSION,
        daemon = {version = "0.0.0", server_now_ms = 1720000000000},
        workspaces = nil,
        profiles = nil,
        agents = nil,
        session_revision = 0,
        cron_revision = 0,
        catalog_rev = sample_catalog_rev(),
        catalog_health = {skipped = nil, load_error = nil},
    }
}

@(test)
test_initialize_params_accepts_valid_bounds :: proc(t: ^testing.T) {
    p := initialize_params_build({name = "yuke-tui", version = "0.0.1"})
    testing.expect(t, initialize_params_validate(p) == .None, "valid params should validate")
}

@(test)
test_initialize_params_rejects_wrong_protocol :: proc(t: ^testing.T) {
    p := initialize_params_build({name = "yuke-tui", version = "0.0.1"})
    p.protocol = 0
    testing.expect(t, initialize_params_validate(p) == .Unsupported_Protocol, "wrong protocol must be rejected")
}

@(test)
test_initialize_params_rejects_oversized_client_fields :: proc(t: ^testing.T) {
    long_name := strings.repeat("n", 65, context.temp_allocator)
    long_version := strings.repeat("v", 33, context.temp_allocator)
    defer free_all(context.temp_allocator)

    bad_name := initialize_params_build({name = long_name, version = "0.0.1"})
    testing.expect(t, initialize_params_validate(bad_name) == .Overflow, "oversized name must overflow")

    bad_version := initialize_params_build({name = "yuke-tui", version = long_version})
    testing.expect(t, initialize_params_validate(bad_version) == .Overflow, "oversized version must overflow")
}

@(test)
test_initialize_params_roundtrip :: proc(t: ^testing.T) {
    input := `{"protocol":1,"client":{"name":"yuke-tui","version":"0.0.1"}}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    p, derr := initialize_params_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, p.protocol, u32(1))
    testing.expect_value(t, p.client.name, "yuke-tui")
    testing.expect_value(t, p.client.version, "0.0.1")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    initialize_params_emit(&e, p)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_initialize_params_from_reader_defaults :: proc(t: ^testing.T) {
    input := `{"client":{"name":"yuke-tui","version":"0.0.1"}}`
    d := decoder_init(input, context.temp_allocator)
    defer free_all(context.temp_allocator)

    p, derr := initialize_params_from_reader(&d)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, p.protocol, u32(PROTOCOL_VERSION))
}

@(test)
test_initialize_result_accepts_valid_full_shape :: proc(t: ^testing.T) {
    h := empty_hello()
    testing.expect(t, initialize_result_validate(h) == .None, "valid result should validate")
}

@(test)
test_initialize_result_rejects_wrong_protocol :: proc(t: ^testing.T) {
    h := empty_hello()
    h.protocol = 0
    testing.expect(t, initialize_result_validate(h) == .Unsupported_Protocol, "wrong protocol must be rejected")
}

@(test)
test_initialize_result_rejects_oversized_daemon_version :: proc(t: ^testing.T) {
    long_version := strings.repeat("v", 33, context.temp_allocator)
    defer free_all(context.temp_allocator)

    h := empty_hello()
    h.daemon.version = long_version
    testing.expect(t, initialize_result_validate(h) == .Overflow, "oversized daemon version must overflow")
}

@(test)
test_initialize_result_rejects_invalid_catalog_revision :: proc(t: ^testing.T) {
    bad: [64]u8
    for i in 0 ..< 64 {
        bad[i] = 'g'
    }

    h := empty_hello()
    h.catalog_rev = Catalog_Rev(bad)
    testing.expect(t, initialize_result_validate(h) == .Invalid_Hex, "non-hex catalog revision must be rejected")
}

@(test)
test_initialize_result_rejects_session_revision_above_max :: proc(t: ^testing.T) {
    h := empty_hello()
    h.session_revision = Session_Revision(MAX_SESSION_REVISION + 1)
    testing.expect(
        t,
        initialize_result_validate(h) == .Out_Of_Range,
        "session revision outside safe range must be rejected",
    )
}

@(test)
test_initialize_result_rejects_cron_revision_above_max :: proc(t: ^testing.T) {
    h := empty_hello()
    h.cron_revision = Cron_Revision(MAX_CRON_REVISION + 1)
    testing.expect(
        t,
        initialize_result_validate(h) == .Out_Of_Range,
        "cron revision outside safe range must be rejected",
    )
}

@(test)
test_initialize_result_agents_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    h := empty_hello()
    h.agents = []string{"main", "worker"}

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    initialize_result_emit(&e, h)
    out := to_string(&e)

    v := decoder_init(out)
    decoded, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, len(decoded.agents), 2)
    testing.expect_value(t, decoded.agents[0], "main")
    testing.expect_value(t, decoded.agents[1], "worker")
    testing.expect(t, initialize_result_validate(decoded) == .None, "agents within bound validate")
}

@(test)
test_initialize_result_rejects_oversized_agent_name :: proc(t: ^testing.T) {
    long_agent := strings.repeat("a", 65, context.temp_allocator)
    defer free_all(context.temp_allocator)

    h := empty_hello()
    h.agents = []string{long_agent}
    testing.expect(t, initialize_result_validate(h) == .Overflow, "oversized agent name must overflow")
}

@(test)
test_initialize_result_rejects_too_many_agents :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    too_many := make([]string, LIMITS.max_agents + 1, context.temp_allocator)
    for i in 0 ..< len(too_many) {
        too_many[i] = "agent"
    }

    h := empty_hello()
    h.agents = too_many
    testing.expect(t, initialize_result_validate(h) == .Overflow, "too many agents must overflow")
}

@(test)
test_initialize_result_rejects_missing_agents :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"protocol":1,
        "daemon":{"version":"0.0.0","server_now_ms":1},
        "workspaces":[],"profiles":[],"session_revision":0,"cron_revision":0,
        "catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health":{"skipped":[],"load_error":null}}`

    v := decoder_init(input, context.temp_allocator)

    _, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "missing agents must be rejected, like profiles")
}

@(test)
test_initialize_result_parses_empty_json :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{
        "protocol": 1,
        "daemon": { "version": "0.0.0", "server_now_ms": 1720000000000 },
        "workspaces": [],
        "profiles": [],
        "agents": [],
        "session_revision": 0,
        "cron_revision": 0,
        "catalog_rev": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health": { "skipped": [], "load_error": null }
    }`

    v := decoder_init(input)

    h, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect(t, initialize_result_validate(h) == .None, "parsed result should validate")
    testing.expect_value(t, len(h.workspaces), 0)
    testing.expect_value(t, h.session_revision, Session_Revision(0))
    testing.expect_value(t, h.cron_revision, Cron_Revision(0))
    testing.expect_value(t, h.capabilities, bit_set[Capability]{})
}

@(test)
test_initialize_result_capabilities_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    h := empty_hello()
    h.capabilities = {.Blob_Upload}

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    initialize_result_emit(&e, h)
    out := to_string(&e)

    v := decoder_init(out)
    decoded, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, decoded.capabilities, bit_set[Capability]{.Blob_Upload})
}

@(test)
test_initialize_result_ignores_unknown_capability :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"protocol":1,
        "daemon":{"version":"0.0.0","server_now_ms":1},
        "workspaces":[],"profiles":[],"agents":[],"session_revision":0,"cron_revision":0,
        "catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health":{"skipped":[],"load_error":null},
        "capabilities":["blob_upload","warp_drive"]}`

    v := decoder_init(input)

    h, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .None, "unknown capability token must be ignored")
    testing.expect_value(t, h.capabilities, bit_set[Capability]{.Blob_Upload})
}

// The set is the contract, not the list: a repeated token names the same surface.
@(test)
test_initialize_result_capabilities_are_idempotent :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"protocol":1,
        "daemon":{"version":"0.0.0","server_now_ms":1},
        "workspaces":[],"profiles":[],"agents":[],"session_revision":0,"cron_revision":0,
        "catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health":{"skipped":[],"load_error":null},
        "capabilities":["blob_upload","blob_upload"]}`

    v := decoder_init(input)

    h, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .None, "a repeated capability token must decode")
    testing.expect_value(t, h.capabilities, bit_set[Capability]{.Blob_Upload})
}

@(test)
test_initialize_result_rejects_non_string_capability :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"protocol":1,
        "daemon":{"version":"0.0.0","server_now_ms":1},
        "workspaces":[],"profiles":[],"agents":[],"session_revision":0,"cron_revision":0,
        "catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health":{"skipped":[],"load_error":null},
        "capabilities":[42]}`

    v := decoder_init(input)

    _, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr != .None, "non-string capability element must be rejected")
}

@(test)
test_initialize_result_ignores_unknown_object_fields :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"protocol":1,
        "daemon":{"version":"0.0.0","server_now_ms":1},
        "workspaces":[],"profiles":[],"agents":[],"session_revision":0,"cron_revision":0,
        "future_field":{"enabled":true},
        "catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health":{"skipped":[],"load_error":null}}`

    v := decoder_init(input)

    h, derr := initialize_result_from_reader(&v)
    testing.expect(t, derr == .None, "unknown object fields must be ignored")
    testing.expect(t, initialize_result_validate(h) == .None, "parsed result should validate")
}
