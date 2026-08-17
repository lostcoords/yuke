// The client (Session) identity: control-plane credential (`yk_sess_…`) and, for
// kind=cli, a persistent X25519 initiator static (`session.key`). Used by the TUI
// to fetch the roster and mint connect tickets. Token-kind sessions have no key file.
package relay

import "core:crypto/ecdh"
import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

SESSION_FILE :: "session.json"
SESSION_KEY_FILE :: "session.key"

Session_Identity :: struct {
    session_id:      string,
    credential:      string,
    relay_url:       string,
    local_device_id: string,
    kind:            string,
    static_key:      ecdh.Private_Key,
    has_static_key:  bool,
    allocator:       mem.Allocator,
}

@(private = "file")
Session_File :: struct {
    session_id:      string `json:"session_id"`,
    credential:      string `json:"credential"`,
    relay_url:       string `json:"relay_url"`,
    local_device_id: string `json:"local_device_id"`,
    kind:            string `json:"kind"`,
}

session_identity_load :: proc(
    dir: string,
    allocator := context.allocator,
) -> (
    id: Session_Identity,
    err: Identity_Error,
) {
    assert(dir != "", "session_identity_load needs a directory")

    path, _ := filepath.join({dir, SESSION_FILE}, context.temp_allocator)
    if !os.exists(path) {
        return {}, .Absent
    }

    bytes, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err != nil {
        return {}, .Unreadable
    }
    defer delete(bytes, context.temp_allocator)

    sf: Session_File
    if json.unmarshal(bytes, &sf, .JSON, context.temp_allocator) != nil {
        return {}, .Malformed
    }
    if sf.session_id == "" || sf.credential == "" || sf.relay_url == "" {
        return {}, .Malformed
    }
    if !strings.has_prefix(sf.credential, "yk_sess_") {
        return {}, .Stale
    }

    out: Session_Identity
    out.allocator = allocator
    cloned: mem.Allocator_Error
    out.session_id, cloned = strings.clone(sf.session_id, allocator)
    if cloned == nil {
        out.credential, cloned = strings.clone(sf.credential, allocator)
    }
    if cloned == nil {
        out.relay_url, cloned = strings.clone(sf.relay_url, allocator)
    }
    if cloned == nil && sf.local_device_id != "" {
        out.local_device_id, cloned = strings.clone(sf.local_device_id, allocator)
    }
    if cloned == nil {
        kind := sf.kind if sf.kind != "" else "cli"
        out.kind, cloned = strings.clone(kind, allocator)
    }
    if cloned != nil {
        session_identity_destroy(&out)
        return {}, .Out_Of_Memory
    }

    if out.kind == "cli" {
        key_path, _ := filepath.join({dir, SESSION_KEY_FILE}, context.temp_allocator)
        if !os.exists(key_path) {
            session_identity_destroy(&out)
            return {}, .Absent
        }
        key_bytes, key_err := os.read_entire_file(key_path, context.temp_allocator)
        if key_err != nil {
            session_identity_destroy(&out)
            return {}, .Unreadable
        }
        defer delete(key_bytes, context.temp_allocator)
        if len(key_bytes) != NOISE_STATIC_KEY_SIZE ||
           !ecdh.private_key_set_bytes(&out.static_key, .X25519, key_bytes) {
            session_identity_destroy(&out)
            return {}, .Key_Invalid
        }
        out.has_static_key = true
    }

    return out, .None
}

session_identity_save :: proc(dir: string, id: ^Session_Identity, allocator := context.allocator) -> Identity_Error {
    assert(dir != "" && id != nil, "session_identity_save needs a directory and identity")
    assert(
        id.session_id != "" && id.credential != "" && id.relay_url != "",
        "session_identity_save needs complete credentials",
    )

    sf := Session_File {
        session_id      = id.session_id,
        credential      = id.credential,
        relay_url       = id.relay_url,
        local_device_id = id.local_device_id,
        kind            = id.kind if id.kind != "" else "cli",
    }
    encoded, marshal_err := json.marshal(sf, {pretty = true}, allocator)
    if marshal_err != nil {
        return .Out_Of_Memory
    }
    defer delete(encoded, allocator)

    path, _ := filepath.join({dir, SESSION_FILE}, context.temp_allocator)
    write_private_file(path, encoded, allocator) or_return

    if id.has_static_key {
        key_bytes: [NOISE_STATIC_KEY_SIZE]u8
        ecdh.private_key_bytes(&id.static_key, key_bytes[:])
        defer mem.zero_slice(key_bytes[:])
        key_path, _ := filepath.join({dir, SESSION_KEY_FILE}, context.temp_allocator)
        return write_private_file(key_path, key_bytes[:], allocator)
    }
    return .None
}

session_identity_destroy :: proc(id: ^Session_Identity) {
    assert(id != nil, "session_identity_destroy needs an identity")
    if id.allocator.procedure != nil {
        delete(id.session_id, id.allocator)
        delete(id.credential, id.allocator)
        delete(id.relay_url, id.allocator)
        delete(id.local_device_id, id.allocator)
        delete(id.kind, id.allocator)
    }
    if id.has_static_key {
        ecdh.private_key_clear(&id.static_key)
    }
    id^ = {}
}
