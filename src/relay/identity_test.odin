package relay

import "core:crypto/ecdh"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Each test uses its own directory: the runner runs tests in parallel, so a shared path
// would let them clobber each other's files.

@(private = "file")
join :: proc(dir, name: string) -> string {
    p, _ := filepath.join({dir, name}, context.temp_allocator)

    return p
}

@(private = "file")
cleanup :: proc(dir: string) {
    _ = os.remove(join(dir, CREDENTIALS_FILE))
    _ = os.remove(join(dir, IDENTITY_KEY_FILE))
    _ = os.remove(dir)
}

@(test)
test_identity_roundtrip :: proc(t: ^testing.T) {
    dir :: "build/identity_test_roundtrip"
    _ = os.make_directory(dir)
    defer cleanup(dir)
    defer free_all(context.temp_allocator)

    // Absent before anything is written.
    _, absent := identity_load(dir, context.allocator)
    testing.expect_value(t, absent, Identity_Error.Absent)

    id: Identity
    id.device_id = "dev-123"
    id.credential = "cred-secret"
    id.relay_url = "wss://relay.yuke.sh"
    testing.expect(t, ecdh.private_key_generate(&id.static_key, .X25519), "keygen")
    defer ecdh.private_key_clear(&id.static_key)

    testing.expect_value(t, identity_save(dir, &id, context.allocator), Identity_Error.None)

    loaded, lerr := identity_load(dir, context.allocator)
    testing.expect_value(t, lerr, Identity_Error.None)
    defer identity_destroy(&loaded)

    testing.expect(t, loaded.device_id == "dev-123", "device_id roundtrip")
    testing.expect(t, loaded.credential == "cred-secret", "credential roundtrip")
    testing.expect(t, loaded.relay_url == "wss://relay.yuke.sh", "relay_url roundtrip")
    testing.expect(t, ecdh.private_key_equal(&loaded.static_key, &id.static_key), "static key roundtrip")
}

@(test)
test_identity_rejects_malformed :: proc(t: ^testing.T) {
    dir :: "build/identity_test_malformed"
    _ = os.make_directory(dir)
    defer cleanup(dir)
    defer free_all(context.temp_allocator)

    cred_path := join(dir, CREDENTIALS_FILE)
    key_path := join(dir, IDENTITY_KEY_FILE)

    good_key: [NOISE_STATIC_KEY_SIZE]u8
    testing.expect(t, os.write_entire_file(key_path, good_key[:]) == nil, "write key")

    // Bad JSON in the credential file.
    testing.expect(t, os.write_entire_file(cred_path, transmute([]u8)string("not json")) == nil, "write cred")
    _, malformed := identity_load(dir, context.allocator)
    testing.expect_value(t, malformed, Identity_Error.Malformed)

    // Missing a required field.
    testing.expect(
        t,
        os.write_entire_file(cred_path, transmute([]u8)string(`{"device_id":"d","credential":"c"}`)) == nil,
        "write cred",
    )
    _, missing := identity_load(dir, context.allocator)
    testing.expect_value(t, missing, Identity_Error.Malformed)

    // Valid credentials but a wrong-size key file.
    testing.expect(
        t,
        os.write_entire_file(
            cred_path,
            transmute([]u8)string(`{"device_id":"d","credential":"c","relay_url":"ws://x"}`),
        ) ==
        nil,
        "write cred",
    )
    testing.expect(t, os.write_entire_file(key_path, []u8{1, 2, 3}) == nil, "write short key")
    _, bad_key := identity_load(dir, context.allocator)
    testing.expect_value(t, bad_key, Identity_Error.Key_Invalid)
}
