package daemon

import "core:mem"
import "core:nbio"
import "core:testing"

import store "src:daemon/store"
import wire "src:wire"

@(private)
catalog_test_store :: proc(t: ^testing.T, d: ^Daemon) -> ^store.Store {
    d.allocator = context.allocator
    s, open_err := store.open_memory()
    testing.expect_value(t, open_err, nil)
    d.store = s
    return s
}

refresh_op_daemon :: proc(t: ^testing.T, d: ^Daemon) -> ^store.Store {
    s := catalog_test_store(t, d)
    testing.expect_value(t, catalog_state_load(d), nil)
    return s
}

@(test)
test_catalog_refresh_settle_applies_on_200 :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // A saved credential makes openai a selected provider.
    testing.expect_value(t, store.credential_api_key_upsert(s, "openai", "sk-test"), nil)
    old_rev := d.catalog.rev

    outcome := catalog_refresh_settle(&d, .Ok, 200, false, transmute([]byte)REFRESH_FEED, `"etag-1"`)
    testing.expect(t, outcome.ok, "a 200 with a selected provider succeeds")
    testing.expect(t, outcome.changed, "importing new models moves the revision")
    testing.expect(t, d.catalog.rev != old_rev, "the held revision moved")
}

@(test)
test_catalog_refresh_settle_noop_on_304 :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    old_rev := d.catalog.rev
    outcome := catalog_refresh_settle(&d, .Ok, 304, false, nil, "")
    testing.expect(t, outcome.ok, "not-modified is a success")
    testing.expect(t, !outcome.changed, "not-modified changes nothing")
    testing.expect_value(t, d.catalog.rev, old_rev)
}

@(test)
test_catalog_refresh_settle_rejects_bad_status :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    old_rev := d.catalog.rev
    outcome := catalog_refresh_settle(&d, .Ok, 503, false, nil, "")
    testing.expect(t, !outcome.ok, "a 5xx status is an error")
    testing.expect(t, !outcome.changed, "a rejected fetch changes nothing")
    testing.expect_value(t, d.catalog.rev, old_rev)
}

@(test)
test_catalog_refresh_settle_rejects_overflow :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    // An over-cap body aborts from on_body, which curl completes as `.Write_Error`.
    outcome := catalog_refresh_settle(&d, .Write_Error, 0, true, nil, "")
    testing.expect(t, !outcome.ok, "an overflowed response is rejected")
}

@(test)
test_catalog_refresh_settle_rejects_transport_failure :: proc(t: ^testing.T) {
    d: Daemon
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    outcome := catalog_refresh_settle(&d, .Couldnt_Connect, 0, false, nil, "")
    testing.expect(t, !outcome.ok, "a transport failure is an error")
}

// The in-flight fetch owns its request id: the inbound frame's arena is reset and wiped
// when the request returns, long before the fetch completes.
@(test)
test_catalog_refresh_owns_its_request_id :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    nbio.acquire_thread_event_loop()
    defer nbio.release_thread_event_loop()

    d: Daemon
    d.loop = nbio.current_thread_event_loop()
    s := refresh_op_daemon(t, &d)
    defer store.close(s)
    defer catalog_state_destroy(&d)

    testing.expect_value(t, catalog_refresh_init(&d), Error.None)
    defer catalog_refresh_destroy(&d)

    // Stands in for the frame arena: the bytes the id points at are reused and wiped as
    // soon as the request that carried it returns.
    borrowed: [7]byte
    copy(borrowed[:], `"req-1"`)

    testing.expect(t, catalog_refresh_begin(&d, 7, wire.Request_Id(string(borrowed[:]))), "the fetch starts")
    defer catalog_refresh_shutdown(&d)

    mem.zero_slice(borrowed[:])

    op := d.catalog_refresh.operation
    if testing.expect(t, op != nil, "the started fetch is the live operation") {
        testing.expect_value(t, string(op.request_id), `"req-1"`)
        testing.expect_value(t, wire.req_id_validate(op.request_id), wire.Validation_Error.None)
    }
}
