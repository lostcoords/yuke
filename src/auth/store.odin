package auth

import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:io"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

AUTH_FILE_VERSION :: 1
AUTH_FILE_MAX_BYTES :: 1024 * 1024
AUTH_FILE_PERMISSIONS :: os.Permissions{.Read_User, .Write_User}
AUTH_DIR_PERMISSIONS :: os.Permissions{.Read_User, .Write_User, .Execute_User}
AUTH_FILE_FORBIDDEN_PERMISSIONS :: os.Permissions {
    .Read_Group,
    .Write_Group,
    .Execute_Group,
    .Read_Other,
    .Write_Other,
    .Execute_Other,
}
AUTH_DIR_FORBIDDEN_PERMISSIONS :: os.Permissions{.Write_Group, .Write_Other}

// OAuth credentials retained only by the daemon. Every string is owned by its
// containing store snapshot.
OAuth_Credentials :: struct {
    access_token:  string,
    refresh_token: string,
    expires_at_ms: u64,
    account_id:    string,
}

// The on-disk provider entry, decoded only in `file_load` to validate the closed
// `type` discriminator; `file_encode` re-emits the tag as a constant.
Entry :: struct {
    kind:          string `json:"type"`,
    access_token:  string `json:"access_token"`,
    refresh_token: string `json:"refresh_token"`,
    expires_at_ms: u64 `json:"expires_at_ms"`,
    account_id:    string `json:"account_id"`,
}

// The decoded shape of `auth.json`; converted to `File` once validated.
File_Wire :: struct {
    version:   u32 `json:"version"`,
    providers: map[string]Entry `json:"providers"`,
}

// The live snapshot; holds `OAuth_Credentials` so copies reuse credentials_clone/destroy.
File :: struct {
    version:   u32,
    providers: map[string]OAuth_Credentials,
}

Error :: enum {
    None,
    Invalid_Options,
    Out_Of_Memory,
    Unsafe_Path,
    Unsafe_Permissions,
    Too_Large,
    Malformed,
    Read_Failed,
    Write_Failed,
}

// A loaded credential snapshot. Mutations first durably replace `auth.json`,
// then publish the matching in-memory map.
Store :: struct {
    path:      string,
    file:      File,
    allocator: mem.Allocator,
}

// Open a credential store. A missing file is an empty version-current snapshot;
// an existing file must be regular, private, bounded, and valid.
open :: proc(path: string, allocator := context.allocator) -> (store: ^Store, err: Error) {
    if path == "" {
        return nil, .Invalid_Options
    }

    allocated, aerr := new(Store, allocator)
    if aerr != nil {
        return nil, .Out_Of_Memory
    }
    store = allocated

    store^ = {}
    store.allocator = allocator
    defer if err != .None {
        close(allocated)
        store = nil
    }

    store.path, aerr = strings.clone(path, allocator)
    if aerr != nil {
        return nil, .Out_Of_Memory
    }

    if !os.exists(path) {
        store.file.version = AUTH_FILE_VERSION
        providers, providers_aerr := make(map[string]OAuth_Credentials, 1, allocator)
        if providers_aerr != nil {
            return nil, .Out_Of_Memory
        }
        store.file.providers = providers

        return store, .None
    }

    file, load_err := file_load(path, allocator)
    if load_err != .None {
        return nil, load_err
    }

    store.file = file
    return store, .None
}

// Release a store and explicitly clear every owned credential buffer first.
close :: proc(store: ^Store) {
    assert(store != nil, "auth store close needs store state")
    file_destroy(&store.file, store.allocator)
    delete(store.path, store.allocator)
    free(store, store.allocator)
}

// Return an owned credential copy for a provider.
credentials_get :: proc(
    store: ^Store,
    provider_id: string,
    allocator := context.allocator,
) -> (
    credentials: OAuth_Credentials,
    found: bool,
    err: Error,
) {
    assert(store != nil, "credentials_get needs an auth store")
    assert(provider_id_valid(provider_id), "credentials_get needs a valid provider id")

    source, exists := store.file.providers[provider_id]
    if !exists {
        return {}, false, .None
    }

    credentials, err = credentials_clone(source, allocator)
    if err != .None {
        return {}, false, err
    }

    return credentials, true, .None
}

// Whether a provider has complete durable OAuth credentials. No secret is copied.
credentials_present :: proc(store: ^Store, provider_id: string) -> bool {
    assert(store != nil, "credentials_present needs an auth store")
    assert(provider_id_valid(provider_id), "credentials_present needs a valid provider id")

    _, present := store.file.providers[provider_id]

    return present
}

// The proactive-refresh clock for a provider, read without copying any secret.
// `present` is false when the provider has no durable credentials.
credentials_expiry :: proc(store: ^Store, provider_id: string) -> (expires_at_ms: u64, present: bool) {
    assert(store != nil, "credentials_expiry needs an auth store")
    assert(provider_id_valid(provider_id), "credentials_expiry needs a valid provider id")

    credentials, exists := store.file.providers[provider_id]
    if !exists {
        return 0, false
    }

    return credentials.expires_at_ms, true
}

// Persist an OAuth entry before making it visible through this store.
credentials_put :: proc(store: ^Store, provider_id: string, credentials: OAuth_Credentials) -> Error {
    assert(store != nil, "credentials_put needs an auth store")
    assert(provider_id_valid(provider_id), "credentials_put needs a valid provider id")
    assert(credentials_valid(credentials), "credentials_put needs complete credentials")

    next, cerr := file_clone(store.file, store.allocator)
    if cerr != .None {
        return cerr
    }
    defer file_destroy(&next, store.allocator)

    if _, found := next.providers[provider_id]; found {
        file_entry_remove(&next, provider_id, store.allocator)
    }

    key, key_aerr := strings.clone(provider_id, store.allocator)
    if key_aerr != nil {
        return .Out_Of_Memory
    }

    cloned, clone_err := credentials_clone(credentials, store.allocator)
    if clone_err != .None {
        delete(key, store.allocator)
        return clone_err
    }

    if map_insert(&next.providers, key, cloned) == nil {
        delete(key, store.allocator)
        credentials_destroy(&cloned, store.allocator)
        return .Out_Of_Memory
    }

    if werr := file_save(store.path, next, store.allocator); werr != .None {
        return werr
    }

    previous := store.file
    store.file = next
    next = {}
    file_destroy(&previous, store.allocator)

    return .None
}

// Remove one provider credential. `removed` is false when the provider was not
// present and no write was needed.
provider_remove :: proc(store: ^Store, provider_id: string) -> (removed: bool, err: Error) {
    assert(store != nil, "provider_remove needs an auth store")
    assert(provider_id_valid(provider_id), "provider_remove needs a valid provider id")

    if _, found := store.file.providers[provider_id]; !found {
        return false, .None
    }

    next, cerr := file_clone(store.file, store.allocator)
    if cerr != .None {
        return false, cerr
    }
    defer file_destroy(&next, store.allocator)

    file_entry_remove(&next, provider_id, store.allocator)

    if werr := file_save(store.path, next, store.allocator); werr != .None {
        return false, werr
    }

    previous := store.file
    store.file = next
    next = {}
    file_destroy(&previous, store.allocator)

    return true, .None
}

// Stable provider ids are short lowercase ASCII tokens, not display names.
provider_id_valid :: proc(provider_id: string) -> bool {
    if len(provider_id) == 0 || len(provider_id) > 64 {
        return false
    }

    for c in transmute([]byte)provider_id {
        switch c {
        case 'a' ..= 'z', '0' ..= '9', '-', '_', '.':
        case:
            return false
        }
    }

    return true
}

credentials_valid :: proc(credentials: OAuth_Credentials) -> bool {
    return(
        credentials.access_token != "" &&
        credentials.refresh_token != "" &&
        credentials.expires_at_ms > 0 &&
        credentials.account_id != "" \
    )
}

credentials_destroy :: proc(credentials: ^OAuth_Credentials, allocator := context.allocator) {
    assert(credentials != nil, "credential cleanup needs a value")
    secret_delete(&credentials.access_token, allocator)
    secret_delete(&credentials.refresh_token, allocator)
    secret_delete(&credentials.account_id, allocator)
    credentials^ = {}
}

credentials_clone :: proc(
    source: OAuth_Credentials,
    allocator := context.allocator,
) -> (
    out: OAuth_Credentials,
    err: Error,
) {
    defer if err != .None {
        credentials_destroy(&out, allocator)
    }

    out.expires_at_ms = source.expires_at_ms
    access, access_aerr := strings.clone(source.access_token, allocator)
    if access_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.access_token = access

    refresh, refresh_aerr := strings.clone(source.refresh_token, allocator)
    if refresh_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.refresh_token = refresh

    account, account_aerr := strings.clone(source.account_id, allocator)
    if account_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.account_id = account

    return out, .None
}

@(private)
file_load :: proc(path: string, allocator: mem.Allocator) -> (out: File, err: Error) {
    info, stat_err := os.lstat(path, allocator)
    if stat_err != nil {
        return {}, .Read_Failed
    }
    defer os.file_info_delete(info, allocator)

    if info.type != .Regular {
        return {}, .Unsafe_Path
    }

    handle, open_err := os.open(path, {.Read})
    if open_err != nil {
        return {}, .Read_Failed
    }
    defer os.close(handle)

    opened, opened_err := os.fstat(handle, allocator)
    if opened_err != nil {
        return {}, .Read_Failed
    }
    defer os.file_info_delete(opened, allocator)

    // Inode identity, not `os.same_file`: it string-compares fullpath, so a symlinked
    // parent (macOS /var) makes lstat and fstat disagree. Closes the lstat/open TOCTOU.
    if opened.type != .Regular || info.inode != opened.inode {
        return {}, .Unsafe_Path
    }

    when ODIN_OS != .Windows {
        if opened.mode & AUTH_FILE_FORBIDDEN_PERMISSIONS != {} {
            return {}, .Unsafe_Permissions
        }
    }

    if opened.size < 0 || opened.size > AUTH_FILE_MAX_BYTES {
        return {}, .Too_Large
    }

    bytes, aerr := make([]byte, int(opened.size), allocator)
    if aerr != nil {
        return {}, .Out_Of_Memory
    }
    defer {
        if len(bytes) > 0 {
            crypto.zero_explicit(raw_data(bytes), len(bytes))
        }
        delete(bytes, allocator)
    }

    if len(bytes) > 0 {
        read, read_err := os.read_full(handle, bytes)
        if read_err != nil || read != len(bytes) {
            return {}, .Read_Failed
        }
    }

    defer if err != .None {
        file_destroy(&out, allocator)
    }

    wire: File_Wire
    if json.unmarshal(bytes, &wire, .JSON, allocator) != nil {
        file_wire_destroy(&wire, allocator)
        return {}, .Malformed
    }
    defer file_wire_destroy(&wire, allocator)

    if wire.version != AUTH_FILE_VERSION {
        return {}, .Malformed
    }

    providers, providers_aerr := make(map[string]OAuth_Credentials, max(1, len(wire.providers)), allocator)
    if providers_aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.version = wire.version
    out.providers = providers

    for provider_id, entry in wire.providers {
        if !provider_id_valid(provider_id) || entry.kind != "oauth" || !credentials_valid(entry_credentials(entry)) {
            return {}, .Malformed
        }

        key, key_aerr := strings.clone(provider_id, allocator)
        if key_aerr != nil {
            return {}, .Out_Of_Memory
        }

        cloned, clone_err := credentials_clone(entry_credentials(entry), allocator)
        if clone_err != .None {
            delete(key, allocator)
            return {}, clone_err
        }

        if map_insert(&out.providers, key, cloned) == nil {
            delete(key, allocator)
            credentials_destroy(&cloned, allocator)
            return {}, .Out_Of_Memory
        }
    }

    return out, .None
}

@(private)
file_valid :: proc(file: File) -> bool {
    if file.version != AUTH_FILE_VERSION {
        return false
    }

    for provider_id, credentials in file.providers {
        if !provider_id_valid(provider_id) || !credentials_valid(credentials) {
            return false
        }
    }

    return true
}

@(private)
file_clone :: proc(source: File, allocator: mem.Allocator) -> (out: File, err: Error) {
    assert(file_valid(source), "auth file clone needs a valid snapshot")
    out.version = source.version
    providers, aerr := make(map[string]OAuth_Credentials, max(1, len(source.providers)), allocator)
    if aerr != nil {
        return {}, .Out_Of_Memory
    }
    out.providers = providers
    defer if err != .None {
        file_destroy(&out, allocator)
    }

    for provider_id, source_credentials in source.providers {
        key, key_aerr := strings.clone(provider_id, allocator)
        if key_aerr != nil {
            return {}, .Out_Of_Memory
        }

        cloned, clone_err := credentials_clone(source_credentials, allocator)
        if clone_err != .None {
            delete(key, allocator)
            return {}, clone_err
        }

        if map_insert(&out.providers, key, cloned) == nil {
            delete(key, allocator)
            credentials_destroy(&cloned, allocator)
            return {}, .Out_Of_Memory
        }
    }

    return out, .None
}

@(private)
file_destroy :: proc(file: ^File, allocator: mem.Allocator) {
    assert(file != nil, "auth file cleanup needs a snapshot")

    if file.providers != nil {
        for provider_id, credentials in file.providers {
            mutable := credentials
            credentials_destroy(&mutable, allocator)
            key := provider_id
            secret_delete(&key, allocator)
        }

        delete(file.providers)
    }

    file^ = {}
}

// Free a decoded wire snapshot; the in-memory `File` clones out of it before this runs.
@(private)
file_wire_destroy :: proc(file: ^File_Wire, allocator: mem.Allocator) {
    assert(file != nil, "auth wire cleanup needs a snapshot")

    if file.providers != nil {
        for provider_id, entry in file.providers {
            mutable := entry
            entry_destroy(&mutable, allocator)
            key := provider_id
            secret_delete(&key, allocator)
        }

        delete(file.providers)
    }

    file^ = {}
}

@(private)
file_entry_remove :: proc(file: ^File, provider_id: string, allocator: mem.Allocator) {
    assert(file != nil, "auth entry removal needs a snapshot")
    assert(file.providers != nil, "auth entry removal needs a provider map")

    credentials, found := file.providers[provider_id]
    assert(found, "auth entry removal needs an existing provider")
    credentials_destroy(&credentials, allocator)

    for key in file.providers {
        if key == provider_id {
            owned_key := key
            delete_key(&file.providers, provider_id)
            secret_delete(&owned_key, allocator)

            return
        }
    }

    unreachable()
}

@(private)
entry_credentials :: proc(entry: Entry) -> OAuth_Credentials {
    assert(entry.kind == "oauth", "only oauth entries become credentials")
    return {
        access_token = entry.access_token,
        refresh_token = entry.refresh_token,
        expires_at_ms = entry.expires_at_ms,
        account_id = entry.account_id,
    }
}

@(private)
entry_destroy :: proc(entry: ^Entry, allocator: mem.Allocator) {
    assert(entry != nil, "auth entry cleanup needs a value")
    secret_delete(&entry.kind, allocator)
    secret_delete(&entry.access_token, allocator)
    secret_delete(&entry.refresh_token, allocator)
    secret_delete(&entry.account_id, allocator)
    entry^ = {}
}

// Wipe and free a secret string, then null the field. Public so the daemon's
// request buffers wipe through one authoritative implementation.
secret_delete :: proc(value: ^string, allocator: mem.Allocator) {
    assert(value != nil, "secret cleanup needs a string")

    if len(value^) > 0 {
        crypto.zero_explicit(raw_data(transmute([]byte)value^), len(value^))
        delete(value^, allocator)
        value^ = ""
    }
}

@(private)
file_save :: proc(path: string, file: File, allocator: mem.Allocator) -> Error {
    assert(path != "", "auth save needs a path")
    assert(file_valid(file), "auth save needs a valid snapshot")

    parent, _ := filepath.split(path)
    if parent == "" {
        return .Invalid_Options
    }

    if mkerr := os.make_directory_all(parent, AUTH_DIR_PERMISSIONS); mkerr != nil && !os.is_dir(parent) {
        return .Write_Failed
    }

    parent_info, parent_err := os.lstat(parent, allocator)
    if parent_err != nil {
        return .Write_Failed
    }
    defer os.file_info_delete(parent_info, allocator)

    if parent_info.type != .Directory {
        return .Unsafe_Path
    }

    when ODIN_OS != .Windows {
        if parent_info.mode & AUTH_DIR_FORBIDDEN_PERMISSIONS != {} {
            return .Unsafe_Permissions
        }
    }

    encoded, encode_err := file_encode(file, allocator)
    if encode_err != .None {
        return encode_err
    }
    defer secret_delete(&encoded, allocator)

    if len(encoded) > AUTH_FILE_MAX_BYTES {
        return .Too_Large
    }

    random: [16]byte
    crypto.rand_bytes(random[:])
    suffix, suffix_aerr := hex.encode(random[:], allocator)
    if suffix_aerr != nil {
        return .Out_Of_Memory
    }
    defer delete(suffix, allocator)

    temp_path, path_aerr := strings.concatenate({path, ".tmp.", string(suffix)}, allocator)
    if path_aerr != nil {
        return .Out_Of_Memory
    }
    defer delete(temp_path, allocator)

    handle, open_err := os.open(temp_path, {.Write, .Create, .Excl}, AUTH_FILE_PERMISSIONS)
    if open_err != nil {
        return .Write_Failed
    }

    renamed := false
    defer if !renamed {
        _ = os.remove(temp_path)
    }

    write_err := Error.None
    if written, err := os.write(handle, transmute([]byte)encoded); err != nil || written != len(encoded) {
        write_err = .Write_Failed
    }

    if write_err == .None && os.fchmod(handle, AUTH_FILE_PERMISSIONS) != nil {
        write_err = .Write_Failed
    }

    if write_err == .None && os.sync(handle) != nil {
        write_err = .Write_Failed
    }

    if os.close(handle) != nil && write_err == .None {
        write_err = .Write_Failed
    }

    if write_err != .None {
        return write_err
    }

    if os.rename(temp_path, path) != nil {
        return .Write_Failed
    }
    renamed = true

    when ODIN_OS != .Windows {
        directory, dir_err := os.open(parent, {.Read})
        if dir_err != nil {
            return .Write_Failed
        }

        sync_err := os.sync(directory)
        close_err := os.close(directory)
        if sync_err != nil || close_err != nil {
            return .Write_Failed
        }
    }

    return .None
}

// Encode the closed auth file shape without ambient allocation. Credential
// writes run on offload workers whose context allocators intentionally panic.
@(private)
file_encode :: proc(file: File, allocator: mem.Allocator) -> (encoded: string, err: Error) {
    assert(file_valid(file), "auth encoder needs a valid snapshot")

    builder, builder_err := strings.builder_make(0, 4096, allocator)
    if builder_err != nil {
        return "", .Out_Of_Memory
    }
    defer if err != .None {
        if len(builder.buf) > 0 {
            crypto.zero_explicit(raw_data(builder.buf[:]), len(builder.buf))
        }
        strings.builder_destroy(&builder)
    }

    keys, keys_aerr := make([]string, len(file.providers), allocator)
    if keys_aerr != nil {
        return "", .Out_Of_Memory
    }
    defer delete(keys, allocator)

    key_index := 0
    for provider_id in file.providers {
        keys[key_index] = provider_id
        key_index += 1
    }
    assert(key_index == len(keys), "auth encoder collected every provider key")
    slice.sort(keys)

    writer := strings.to_writer(&builder)
    json_write_raw(writer, "{\n  \"version\": 1,\n  \"providers\": {") or_return
    for provider_id, index in keys {
        credentials := file.providers[provider_id]
        json_write_raw(writer, "\n    ") or_return
        json_write_string(writer, provider_id) or_return
        json_write_raw(writer, ": {\n      \"type\": \"oauth\",\n      \"access_token\": ") or_return
        json_write_string(writer, credentials.access_token) or_return
        json_write_raw(writer, ",\n      \"refresh_token\": ") or_return
        json_write_string(writer, credentials.refresh_token) or_return
        json_write_raw(writer, ",\n      \"expires_at_ms\": ") or_return
        json_write_u64(writer, credentials.expires_at_ms) or_return
        json_write_raw(writer, ",\n      \"account_id\": ") or_return
        json_write_string(writer, credentials.account_id) or_return
        json_write_raw(writer, "\n    }") or_return

        if index + 1 < len(keys) {
            json_write_raw(writer, ",") or_return
        }
    }
    json_write_raw(writer, "\n  }\n}\n") or_return

    encoded = strings.to_string(builder)

    return encoded, .None
}

@(private)
json_write_raw :: proc(writer: io.Writer, value: string) -> Error {
    _, write_err := io.write_string(writer, value)

    return .None if write_err == .None else .Out_Of_Memory
}

@(private)
json_write_string :: proc(writer: io.Writer, value: string) -> Error {
    _, write_err := io.write_quoted_string(writer, value, '"', nil, true)

    return .None if write_err == .None else .Out_Of_Memory
}

@(private)
json_write_u64 :: proc(writer: io.Writer, value: u64) -> Error {
    _, write_err := io.write_u64(writer, value)

    return .None if write_err == .None else .Out_Of_Memory
}
