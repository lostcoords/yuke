package daemon

import "core:testing"

import store "src:daemon/store"

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
