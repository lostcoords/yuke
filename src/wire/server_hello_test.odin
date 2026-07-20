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

// Minimal valid Server_Hello fixture for tests.
empty_hello :: proc() -> Server_Hello {
    return Server_Hello {
        type = "hello",
        protocol = PROTOCOL_VERSION,
        daemon = Daemon_Info{version = "0.0.0", server_now_ms = 1720000000000},
        workspaces = nil,
        profiles = nil,
        session_revision = 0,
        cron_revision = 0,
        catalog_rev = sample_catalog_rev(),
        catalog_health = Catalog_Health{skipped = nil, load_error = nil},
    }
}

@(test)
test_server_hello_accepts_valid_full_shape :: proc(t: ^testing.T) {
    h := empty_hello()
    testing.expect(t, server_hello_validate(h) == .None, "valid hello should validate")
}

@(test)
test_server_hello_rejects_bad_type :: proc(t: ^testing.T) {
    h := empty_hello()
    h.type = "client.hello"
    testing.expect(t, server_hello_validate(h) == .Bad_Frame_Type, "bad type must be rejected")
}

@(test)
test_server_hello_rejects_wrong_protocol :: proc(t: ^testing.T) {
    h := empty_hello()
    h.protocol = 0
    testing.expect(t, server_hello_validate(h) == .Unsupported_Protocol, "wrong protocol must be rejected")
}

@(test)
test_server_hello_rejects_oversized_daemon_version :: proc(t: ^testing.T) {
    long_version := strings.repeat("v", 33, context.temp_allocator)
    defer free_all(context.temp_allocator)

    h := empty_hello()
    h.daemon.version = long_version
    testing.expect(t, server_hello_validate(h) == .Overflow, "oversized daemon version must overflow")
}

@(test)
test_server_hello_rejects_invalid_catalog_revision :: proc(t: ^testing.T) {
    bad: [64]u8
    for i in 0 ..< 64 {
        bad[i] = 'g'
    }

    h := empty_hello()
    h.catalog_rev = Catalog_Rev(bad)
    testing.expect(t, server_hello_validate(h) == .Invalid_Hex, "non-hex catalog revision must be rejected")
}

@(test)
test_server_hello_rejects_session_revision_above_max :: proc(t: ^testing.T) {
    h := empty_hello()
    h.session_revision = Session_Revision(MAX_SESSION_REVISION + 1)
    testing.expect(
        t,
        server_hello_validate(h) == .Out_Of_Range,
        "session revision outside safe range must be rejected",
    )
}

@(test)
test_server_hello_rejects_cron_revision_above_max :: proc(t: ^testing.T) {
    h := empty_hello()
    h.cron_revision = Cron_Revision(MAX_CRON_REVISION + 1)
    testing.expect(t, server_hello_validate(h) == .Out_Of_Range, "cron revision outside safe range must be rejected")
}

@(test)
test_server_hello_parses_empty_hello_json :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{
        "type": "hello",
        "protocol": 1,
        "daemon": { "version": "0.0.0", "server_now_ms": 1720000000000 },
        "workspaces": [],
        "profiles": [],
        "session_revision": 0,
        "cron_revision": 0,
        "catalog_rev": "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health": { "skipped": [], "load_error": null }
    }`

    v := decoder_init(input)

    h, derr := server_hello_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect(t, server_hello_validate(h) == .None, "parsed hello should validate")
    testing.expect_value(t, len(h.workspaces), 0)
    testing.expect_value(t, h.session_revision, Session_Revision(0))
    testing.expect_value(t, h.cron_revision, Cron_Revision(0))
}

@(test)
test_server_hello_ignores_unknown_object_fields :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"hello","protocol":1,
        "daemon":{"version":"0.0.0","server_now_ms":1},
        "workspaces":[],"profiles":[],"session_revision":0,"cron_revision":0,
        "future_field":{"enabled":true},
        "catalog_rev":"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        "catalog_health":{"skipped":[],"load_error":null}}`

    v := decoder_init(input)

    h, derr := server_hello_from_reader(&v)
    testing.expect(t, derr == .None, "unknown object fields must be ignored")
    testing.expect(t, server_hello_validate(h) == .None, "parsed hello should validate")
}
