// The daemon (Device) identity: control-plane credential (`yk_dev_…`) and X25519
// responder static. Used only by `yuked` to park (`link_tickets`). Client
// identity is `session.json` / `session.key`. Credentials are a plain data file.
package relay

import "core:crypto/ecdh"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "libs:json"

// The credential file inside the config directory: the device's control-plane identity.
CREDENTIALS_FILE :: "credentials.json"

// The static key file inside the config directory: the device's X25519 private key, 32 raw
// bytes. A plain key file, never JSON.
IDENTITY_KEY_FILE :: "identity.key"

// Owner read/write only, matching the secret nature of the credential and key.
IDENTITY_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}

// A device identity: the control-plane credential and the X25519 static keypair. Free with
// `identity_destroy`, which wipes the private key. Strings are owned by `allocator`.
Identity :: struct {
    // Opaque account device id; how peers address this device.
    device_id:  string,

    // Bearer credential presented to the control plane. Secret.
    credential: string,

    // Control-plane-provided relay endpoint (`ws://…`/`wss://…`).
    relay_url:  string,

    // The X25519 static private key: this device's Noise identity.
    static_key: ecdh.Private_Key,

    // @private
    // Backs the owned strings, for `identity_destroy`.
    allocator:  mem.Allocator,
}

// Why an identity could not be loaded.
Identity_Error :: enum {
    // No error.
    None,

    // No credential or key file: the device is not enrolled.
    Absent,

    // A file exists but could not be read.
    Unreadable,

    // The credential JSON is malformed or missing a required field.
    Malformed,

    // The key file is not a valid 32-byte X25519 private key.
    Key_Invalid,

    // A file could not be written.
    Write_Failed,

    // Pre-split files: credential is not `yk_dev_…`. Delete them or pass --force.
    Stale,
}

// The JSON shape of `credentials.json`. The X25519 private key is stored separately as raw
// bytes, never in this file.
@(private = "file")
Credentials_File :: struct {
    device_id:  string `json:"device_id"`,
    credential: string `json:"credential"`,
    relay_url:  string `json:"relay_url"`,
}

// Load the device identity from `dir`. `.Absent` when either file is missing (not enrolled);
// the credential fields must all be present and the key must be a valid X25519 private key.
identity_load :: proc(dir: string, allocator := context.allocator) -> (id: Identity, err: Identity_Error) {
    assert(dir != "", "identity_load needs a directory")

    cred_path, _ := filepath.join({dir, CREDENTIALS_FILE}, context.temp_allocator)
    key_path, _ := filepath.join({dir, IDENTITY_KEY_FILE}, context.temp_allocator)

    if !os.exists(cred_path) || !os.exists(key_path) do return {}, .Absent

    cred_bytes, cred_err := os.read_entire_file(cred_path, context.temp_allocator)
    if cred_err != nil do return {}, .Unreadable
    defer delete(cred_bytes, context.temp_allocator)

    cf: Credentials_File
    if json.unmarshal(cred_bytes, &cf, .JSON, context.temp_allocator) != nil do return {}, .Malformed

    if cf.device_id == "" || cf.credential == "" || cf.relay_url == "" do return {}, .Malformed
    if !strings.has_prefix(cf.credential, "yk_dev_") do return {}, .Stale

    key_bytes, key_err := os.read_entire_file(key_path, context.temp_allocator)
    if key_err != nil do return {}, .Unreadable
    defer delete(key_bytes, context.temp_allocator)

    if len(key_bytes) != NOISE_STATIC_KEY_SIZE do return {}, .Key_Invalid

    out: Identity
    out.allocator = allocator
    if !ecdh.private_key_set_bytes(&out.static_key, .X25519, key_bytes) do return {}, .Key_Invalid

    out.device_id = strings.clone(cf.device_id, allocator)
    out.credential = strings.clone(cf.credential, allocator)
    out.relay_url = strings.clone(cf.relay_url, allocator)

    return out, .None
}

// Write `id` to `dir` as `credentials.json` + `identity.key`, each mode 0600 and replaced
// atomically. The directory must already exist.
identity_save :: proc(dir: string, id: ^Identity, allocator := context.allocator) -> Identity_Error {
    assert(dir != "", "identity_save needs a directory")
    assert(id != nil, "identity_save needs an identity")
    assert(id.device_id != "" && id.credential != "" && id.relay_url != "", "identity_save needs complete credentials")

    cf := Credentials_File {
        device_id  = id.device_id,
        credential = id.credential,
        relay_url  = id.relay_url,
    }
    encoded, _ := json.marshal(cf, {pretty = true}, allocator)
    defer delete(encoded, allocator)

    key_bytes: [NOISE_STATIC_KEY_SIZE]u8
    ecdh.private_key_bytes(&id.static_key, key_bytes[:])
    defer mem.zero_slice(key_bytes[:])

    cred_path, _ := filepath.join({dir, CREDENTIALS_FILE}, context.temp_allocator)
    key_path, _ := filepath.join({dir, IDENTITY_KEY_FILE}, context.temp_allocator)

    write_private_file(cred_path, encoded, allocator) or_return

    return write_private_file(key_path, key_bytes[:], allocator)
}

// Release the identity's owned strings and wipe the private key. Safe on a zero-valued
// identity.
identity_destroy :: proc(id: ^Identity) {
    assert(id != nil, "identity_destroy needs an identity")

    if id.allocator.procedure != nil {
        delete(id.device_id, id.allocator)
        delete(id.credential, id.allocator)
        delete(id.relay_url, id.allocator)
    }

    ecdh.private_key_clear(&id.static_key)
    id^ = {}
}

// Write `data` to `path` privately: a fresh temp beside it (0600), fsync, then atomic rename.
write_private_file :: proc(path: string, data: []byte, allocator: mem.Allocator) -> Identity_Error {
    temp_path := strings.concatenate({path, ".tmp"}, allocator)
    defer delete(temp_path, allocator)

    handle, open_err := os.open(temp_path, {.Write, .Create, .Excl}, IDENTITY_FILE_PERMISSIONS)
    if open_err != nil do return .Write_Failed

    renamed := false
    defer if !renamed do _ = os.remove(temp_path)

    ok := true
    if written, err := os.write(handle, data); err != nil || written != len(data) do ok = false

    if ok && os.fchmod(handle, IDENTITY_FILE_PERMISSIONS) != nil do ok = false

    if ok && os.sync(handle) != nil do ok = false

    if os.close(handle) != nil do ok = false

    if !ok do return .Write_Failed

    if os.rename(temp_path, path) != nil do return .Write_Failed

    renamed = true

    return .None
}
