package store

import "core:mem"
import "core:strings"
import "core:testing"

import "libs:bindings/sqlite"
import "libs:testsupport"

@(test)
test_credentials_round_trip_both_arms :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, credential_api_key_upsert(s, "anthropic", "sk-ant-secret"), nil)
    testing.expect_value(
        t,
        credential_oauth_upsert(
            s,
            "codex",
            {
                access_token = "access-codex",
                refresh_token = "refresh-codex",
                expires_at_ms = 1_800_000_000_000,
                account_id = "account-codex",
            },
        ),
        nil,
    )
    testing.expect_value(
        t,
        credential_oauth_upsert(
            s,
            "xai",
            {access_token = "access-xai", refresh_token = "refresh-xai", expires_at_ms = 1_800_000_000_001},
        ),
        nil,
    )

    credentials, load_err := credentials_load(s)
    testing.expect_value(t, load_err, nil)
    defer credentials_destroy(credentials)
    testing.expect_value(t, len(credentials), 3)

    testing.expect_value(t, credentials[0].provider_id, "anthropic")
    testing.expect_value(t, credentials[0].kind, Credential_Kind.Api_Key)
    testing.expect_value(t, credentials[0].api_key, "sk-ant-secret")

    testing.expect_value(t, credentials[1].provider_id, "codex")
    testing.expect_value(t, credentials[1].kind, Credential_Kind.OAuth)
    testing.expect_value(t, credentials[1].access_token, "access-codex")
    testing.expect_value(t, credentials[1].refresh_token, "refresh-codex")
    testing.expect_value(t, credentials[1].expires_at_ms, u64(1_800_000_000_000))
    testing.expect_value(t, credentials[1].account_id, "account-codex")

    testing.expect_value(t, credentials[2].provider_id, "xai")
    testing.expect_value(t, credentials[2].kind, Credential_Kind.OAuth)
    testing.expect_value(t, credentials[2].account_id, "")
}

@(test)
test_credential_upsert_replaces_the_closed_arm_and_remove_is_idempotent :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, credential_api_key_upsert(s, "openai", "first-key"), nil)
    testing.expect_value(
        t,
        credential_oauth_upsert(
            s,
            "openai",
            {access_token = "access", refresh_token = "refresh", expires_at_ms = 100},
        ),
        nil,
    )

    credentials, load_err := credentials_load(s)
    testing.expect_value(t, load_err, nil)
    testing.expect_value(t, len(credentials), 1)
    testing.expect_value(t, credentials[0].kind, Credential_Kind.OAuth)
    testing.expect_value(t, credentials[0].api_key, "")
    credentials_destroy(credentials)

    testing.expect_value(t, credential_api_key_upsert(s, "openai", "second-key"), nil)
    credentials, load_err = credentials_load(s)
    testing.expect_value(t, load_err, nil)
    testing.expect_value(t, len(credentials), 1)
    testing.expect_value(t, credentials[0].kind, Credential_Kind.Api_Key)
    testing.expect_value(t, credentials[0].api_key, "second-key")
    testing.expect_value(t, credentials[0].access_token, "")
    credentials_destroy(credentials)

    removed, remove_err := credential_remove(s, "openai")
    testing.expect_value(t, remove_err, nil)
    testing.expect(t, removed, "the existing credential is removed")

    removed, remove_err = credential_remove(s, "openai")
    testing.expect_value(t, remove_err, nil)
    testing.expect(t, !removed, "removing an absent credential is a no-op")

    credentials, load_err = credentials_load(s)
    testing.expect_value(t, load_err, nil)
    testing.expect_value(t, len(credentials), 0)
    credentials_destroy(credentials)
}

@(test)
test_credential_inputs_are_bounded_before_binding :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    too_long_secret := strings.repeat("x", CREDENTIAL_SECRET_MAX_BYTES + 1, context.temp_allocator)
    too_long_account := strings.repeat("a", CREDENTIAL_ACCOUNT_ID_MAX_BYTES + 1, context.temp_allocator)

    testing.expect_value(t, credential_api_key_upsert(s, "", "key"), Store_Error.Invalid_Credential)
    testing.expect_value(t, credential_api_key_upsert(s, "OpenAI", "key"), Store_Error.Invalid_Credential)
    testing.expect_value(t, credential_api_key_upsert(s, "openai", ""), Store_Error.Invalid_Credential)
    testing.expect_value(t, credential_api_key_upsert(s, "openai", too_long_secret), Store_Error.Invalid_Credential)
    testing.expect_value(
        t,
        credential_oauth_upsert(s, "codex", {access_token = "", refresh_token = "refresh", expires_at_ms = 1}),
        Store_Error.Invalid_Credential,
    )
    testing.expect_value(
        t,
        credential_oauth_upsert(s, "codex", {access_token = "access", refresh_token = "refresh", expires_at_ms = 0}),
        Store_Error.Invalid_Credential,
    )
    testing.expect_value(
        t,
        credential_oauth_upsert(
            s,
            "codex",
            {access_token = "access", refresh_token = "refresh", expires_at_ms = 1, account_id = too_long_account},
        ),
        Store_Error.Invalid_Credential,
    )
    removed, remove_err := credential_remove(s, "bad/provider")
    testing.expect(t, !removed, "an invalid provider id removes nothing")
    testing.expect_value(t, remove_err, Store_Error.Invalid_Credential)

    rows, rows_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM provider_credentials")
    testing.expect_value(t, rows_err, sqlite.Result.Ok)
    testing.expect_value(t, rows, i64(0))
}

@(test)
test_credential_table_rejects_mixed_empty_and_incomplete_rows :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    invalid := []string {
        "INSERT INTO provider_credentials(provider_id, kind, api_key, access_token) VALUES ('mixed', 'api_key', 'key', 'access')",
        "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES ('empty-key', 'api_key', '')",
        "INSERT INTO provider_credentials(provider_id, kind, access_token, expires_at_ms) VALUES ('missing-refresh', 'oauth', 'access', 1)",
        "INSERT INTO provider_credentials(provider_id, kind, access_token, refresh_token, expires_at_ms) VALUES ('empty-access', 'oauth', '', 'refresh', 1)",
        "INSERT INTO provider_credentials(provider_id, kind, access_token, refresh_token, expires_at_ms) VALUES ('zero-expiry', 'oauth', 'access', 'refresh', 0)",
        "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES ('Uppercase', 'api_key', 'key')",
        "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES ('unknown', 'token', 'key')",
        "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES (x'00', 'api_key', 'key')",
        "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES (CAST(x'6f70656e6169006576696c' AS TEXT), 'api_key', 'key')",
        "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES ('blob-secret', 'api_key', x'00')",
    }

    for sql in invalid {
        testing.expect_value(t, sqlite.exec(s.writer, sql), sqlite.Result.Constraint)
    }

    rows, rows_err := sqlite.query_one_i64(s.writer, "SELECT count(*) FROM provider_credentials")
    testing.expect_value(t, rows_err, sqlite.Result.Ok)
    testing.expect_value(t, rows, i64(0))
}

// Every allocation in a multi-row load is failed in turn. Already cloned keys and
// tokens must be released on every path; the store returns no partial credential list.
@(test)
test_credential_load_allocation_failures_leak_nothing :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, credential_api_key_upsert(s, "anthropic", "api-secret"), nil)
    testing.expect_value(
        t,
        credential_oauth_upsert(
            s,
            "codex",
            {
                access_token = "access-secret",
                refresh_token = "refresh-secret",
                expires_at_ms = 100,
                account_id = "account-secret",
            },
        ),
        nil,
    )

    completed := false
    for fail_at in 0 ..< 16 {
        track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&track, context.allocator)
        tracked := mem.tracking_allocator(&track)

        failing: testsupport.Failing_Allocator
        testsupport.failing_allocator_init(&failing, tracked, fail_at)
        credentials, load_err := credentials_load(s, testsupport.failing_allocator(&failing))

        if load_err == nil {
            completed = true
            credentials_destroy(credentials)
        } else {
            testing.expect_value(t, load_err, Store_Error.Alloc_Failed)
            testing.expect(t, credentials == nil, "a failed load returns no partial credentials")
        }

        testing.expectf(
            t,
            len(track.allocation_map) == 0,
            "fail_at %d leaked %d allocations",
            fail_at,
            len(track.allocation_map),
        )
        testing.expectf(
            t,
            len(track.bad_free_array) == 0,
            "fail_at %d made %d bad frees",
            fail_at,
            len(track.bad_free_array),
        )
        mem.tracking_allocator_destroy(&track)

        if completed {
            break
        }
    }

    testing.expect(t, completed, "the allocation sweep eventually reaches a successful load")
}

// A persisted row is operating input, even when local corruption bypasses CHECK.
// Refuse it without asserting and release a valid row already cloned before it.
@(test)
test_credential_load_rejects_corrupt_rows_without_leaking_prefix :: proc(t: ^testing.T) {
    s, err := open_memory()
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, credential_api_key_upsert(s, "a-valid", "api-secret"), nil)
    testing.expect_value(t, sqlite.exec(s.writer, "PRAGMA ignore_check_constraints = ON"), sqlite.Result.Ok)
    testing.expect_value(
        t,
        sqlite.exec(
            s.writer,
            "INSERT INTO provider_credentials(provider_id, kind, api_key) VALUES ('z-corrupt', 'oauth', 'mixed')",
        ),
        sqlite.Result.Ok,
    )

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    credentials, load_err := credentials_load(s, tracked)
    testing.expect_value(t, load_err, Store_Error.Invalid_Row)
    testing.expect(t, credentials == nil, "a corrupt suffix returns no valid prefix")
    testing.expect_value(t, len(track.allocation_map), 0)
    testing.expect_value(t, len(track.bad_free_array), 0)
}
