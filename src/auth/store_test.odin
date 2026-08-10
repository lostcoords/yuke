package auth

import "core:crypto"
import "core:encoding/hex"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

test_credentials :: proc(access := "access-one") -> OAuth_Credentials {
    return {
        access_token = access,
        refresh_token = "refresh-one",
        expires_at_ms = 1_900_000_000_000,
        account_id = "account-one",
    }
}

test_dir :: proc(tag: string, allocator := context.allocator) -> string {
    random: [8]byte
    crypto.rand_bytes(random[:])
    suffix, suffix_aerr := hex.encode(random[:], allocator)
    if suffix_aerr != nil {
        return ""
    }
    defer delete(suffix, allocator)

    name, name_aerr := strings.concatenate({"yuke-auth-", tag, "-", string(suffix)}, allocator)
    if name_aerr != nil {
        return ""
    }
    defer delete(name, allocator)

    temp, temp_err := os.temp_dir(allocator)
    if temp_err != nil {
        return ""
    }
    defer delete(temp, allocator)

    path, path_err := filepath.join({temp, name}, allocator)
    if path_err != nil {
        return ""
    }

    return path
}

@(test)
test_store_missing_is_empty_and_oauth_roundtrips :: proc(t: ^testing.T) {
    dir := test_dir("roundtrip")
    testing.expect(t, dir != "", "temp path")
    defer {
        _ = os.remove_all(dir)
        delete(dir)
    }

    path, path_err := filepath.join({dir, "auth.json"})
    if path_err != nil {
        testing.expect(t, false, "join auth path")
        return
    }
    defer delete(path)

    store, err := open(path)
    testing.expect_value(t, err, Error.None)
    testing.expect(t, store != nil, "store opens")
    testing.expect(t, !credentials_present(store, "openai-codex"), "missing provider is signed out")

    _, found, get_err := credentials_get(store, "openai-codex")
    testing.expect_value(t, get_err, Error.None)
    testing.expect(t, !found, "missing provider")

    testing.expect_value(t, credentials_put(store, "openai-codex", test_credentials()), Error.None)
    testing.expect(t, credentials_present(store, "openai-codex"), "stored provider is signed in")
    close(store)

    reopened, reopen_err := open(path)
    testing.expect_value(t, reopen_err, Error.None)
    defer close(reopened)

    credentials, present, credential_err := credentials_get(reopened, "openai-codex")
    testing.expect_value(t, credential_err, Error.None)
    testing.expect(t, present, "provider persisted")
    testing.expect_value(t, credentials.access_token, "access-one")
    testing.expect_value(t, credentials.refresh_token, "refresh-one")
    testing.expect_value(t, credentials.account_id, "account-one")
    credentials_destroy(&credentials)
}

@(test)
test_store_update_preserves_other_provider_and_logout_removes_one :: proc(t: ^testing.T) {
    dir := test_dir("merge")
    defer {
        _ = os.remove_all(dir)
        delete(dir)
    }
    path, path_err := filepath.join({dir, "auth.json"})
    if path_err != nil {
        testing.expect(t, false, "join auth path")
        return
    }
    defer delete(path)

    store, err := open(path)
    testing.expect_value(t, err, Error.None)
    defer close(store)

    testing.expect_value(t, credentials_put(store, "openai-codex", test_credentials("first")), Error.None)
    testing.expect_value(t, credentials_put(store, "another", test_credentials("second")), Error.None)

    removed, remove_err := provider_remove(store, "openai-codex")
    testing.expect_value(t, remove_err, Error.None)
    testing.expect(t, removed, "existing provider removed")

    _, first_found, first_err := credentials_get(store, "openai-codex")
    testing.expect_value(t, first_err, Error.None)
    testing.expect(t, !first_found, "removed provider absent")

    second, second_found, second_err := credentials_get(store, "another")
    testing.expect_value(t, second_err, Error.None)
    testing.expect(t, second_found, "unrelated provider preserved")
    testing.expect_value(t, second.access_token, "second")
    credentials_destroy(&second)
}

@(test)
test_store_rejects_malformed_and_over_permissive_files :: proc(t: ^testing.T) {
    dir := test_dir("reject")
    defer {
        _ = os.remove_all(dir)
        delete(dir)
    }
    testing.expect(t, os.make_directory_all(dir, AUTH_DIR_PERMISSIONS) == nil, "make temp dir")

    path, path_err := filepath.join({dir, "auth.json"})
    if path_err != nil {
        testing.expect(t, false, "join auth path")
        return
    }
    defer delete(path)

    testing.expect(t, os.write_entire_file(path, "{broken", AUTH_FILE_PERMISSIONS, true) == nil, "seed malformed")
    testing.expect(t, os.chmod(path, AUTH_FILE_PERMISSIONS) == nil, "tighten malformed fixture")
    malformed, malformed_err := open(path)
    testing.expect(t, malformed == nil, "malformed store refused")
    testing.expect_value(t, malformed_err, Error.Malformed)

    when ODIN_OS != .Windows {
        valid := "{\n  \"version\": 1,\n  \"providers\": {}\n}\n"
        testing.expect(t, os.write_entire_file(path, valid, AUTH_FILE_PERMISSIONS, true) == nil, "seed valid fixture")
        testing.expect(t, os.chmod(path, os.perm(0o644)) == nil, "expose fixture")

        exposed, exposed_err := open(path)
        testing.expect(t, exposed == nil, "exposed store refused")
        testing.expect_value(t, exposed_err, Error.Unsafe_Permissions)
    }
}

@(test)
test_store_refuses_to_write_through_shared_writable_directory :: proc(t: ^testing.T) {
    when ODIN_OS != .Windows {
        dir := test_dir("writable-parent")
        defer {
            _ = os.remove_all(dir)
            delete(dir)
        }
        testing.expect(t, os.make_directory_all(dir, os.perm(0o775)) == nil, "make shared writable directory")
        testing.expect(t, os.chmod(dir, os.perm(0o775)) == nil, "share directory writes")

        path, path_err := filepath.join({dir, "auth.json"})
        if path_err != nil {
            testing.expect(t, false, "join auth path")
            return
        }
        defer delete(path)

        store, open_err := open(path)
        testing.expect_value(t, open_err, Error.None)
        defer close(store)

        testing.expect_value(t, credentials_put(store, "openai-codex", test_credentials()), Error.Unsafe_Permissions)
        testing.expect(t, !credentials_present(store, "openai-codex"), "failed write is never published")
    }
}

@(test)
test_store_allows_readable_config_directory_with_private_file :: proc(t: ^testing.T) {
    when ODIN_OS != .Windows {
        dir := test_dir("readable-parent")
        defer {
            _ = os.remove_all(dir)
            delete(dir)
        }
        testing.expect(t, os.make_directory_all(dir, os.perm(0o755)) == nil, "make readable config directory")
        testing.expect(t, os.chmod(dir, os.perm(0o755)) == nil, "make config directory readable")

        path, path_err := filepath.join({dir, "auth.json"})
        if path_err != nil {
            testing.expect(t, false, "join auth path")
            return
        }
        defer delete(path)

        store, open_err := open(path)
        testing.expect_value(t, open_err, Error.None)
        defer close(store)

        testing.expect_value(t, credentials_put(store, "openai-codex", test_credentials()), Error.None)
        info, info_err := os.stat(path, context.allocator)
        testing.expect(t, info_err == nil, "stat auth file")
        defer os.file_info_delete(info, context.allocator)
        testing.expect_value(t, info.mode & AUTH_FILE_FORBIDDEN_PERMISSIONS, os.Permissions{})
    }
}

@(test)
test_provider_id_is_closed_ascii_token :: proc(t: ^testing.T) {
    testing.expect(t, provider_id_valid("openai-codex"), "stable provider id")
    testing.expect(t, !provider_id_valid("OpenAI Codex"), "display name is not an id")
    testing.expect(t, !provider_id_valid("../openai"), "path syntax rejected")
    testing.expect(t, !provider_id_valid(""), "empty id rejected")
}

@(test)
test_credentials_require_account_id :: proc(t: ^testing.T) {
    credentials := test_credentials()
    testing.expect(t, credentials_valid(credentials), "complete Codex credentials")

    credentials.account_id = ""
    testing.expect(t, !credentials_valid(credentials), "account id is required for Codex requests")
}
