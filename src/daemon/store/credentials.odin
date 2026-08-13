package store

import "core:mem"
import "core:strings"

import "src:daemon/store/queries"
import "src:secret"

import "libs:bindings/sqlite"

PROVIDER_ID_MAX_BYTES :: 64
CREDENTIAL_SECRET_MAX_BYTES :: 64 * 1024
CREDENTIAL_ACCOUNT_ID_MAX_BYTES :: 4 * 1024
CREDENTIAL_EXPIRES_AT_MS_MAX :: 9_007_199_254_740_991

@(private)
CREDENTIALS_LOAD_SQL :: `SELECT provider_id, kind, api_key, access_token,
    refresh_token, expires_at_ms, account_id
FROM provider_credentials ORDER BY provider_id`

@(private)
CREDENTIAL_STATUSES_LOAD_SQL :: `SELECT provider_id, kind
FROM provider_credentials ORDER BY provider_id`

Credential_Kind :: enum {
    Api_Key,
    OAuth,
}

// Owned secret-free projection used by auth.list.
Credential_Status :: struct {
    provider_id: string,
    kind:        Credential_Kind,
}

OAuth_Credential :: struct {
    access_token:  string,
    refresh_token: string,
    expires_at_ms: u64,
    account_id:    string,
}

// Owned store row. Only the fields selected by `kind` are populated.
Credential :: struct {
    provider_id:   string,
    kind:          Credential_Kind,
    api_key:       string,
    access_token:  string,
    refresh_token: string,
    expires_at_ms: u64,
    account_id:    string,
}

@(private)
Credential_Row :: struct {
    provider_id:   string `sql:",borrowed"`,
    kind:          string `sql:",borrowed"`,
    api_key:       Maybe(string) `sql:",borrowed"`,
    access_token:  Maybe(string) `sql:",borrowed"`,
    refresh_token: Maybe(string) `sql:",borrowed"`,
    expires_at_ms: Maybe(u64),
    account_id:    Maybe(string) `sql:",borrowed"`,
}

@(private)
Credential_Status_Row :: struct {
    provider_id: string `sql:",borrowed"`,
    kind:        string `sql:",borrowed"`,
}

credential_statuses_load :: proc(
    s: ^Store,
    allocator := context.allocator,
) -> (
    statuses: [dynamic]Credential_Status,
    err: Error,
) {
    assert(s != nil, "credential_statuses_load needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a credential status read needs an allocator")

    st := sqlite.prepare(s.writer, CREDENTIAL_STATUSES_LOAD_SQL) or_return
    defer sqlite.finalize(st)

    list: [dynamic]Credential_Status
    list.allocator = allocator
    defer if err != nil {
        credential_statuses_destroy(list)
    }

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        row: Credential_Status_Row
        sqlite.scan_row(st, &row, allocator) or_return
        kind, valid := credential_kind_parse(row.kind)
        if !valid || !credential_provider_id_valid(row.provider_id) {
            return nil, .Invalid_Row
        }

        provider_id := credential_clone(row.provider_id, allocator) or_return
        if _, append_err := append(&list, Credential_Status{provider_id = provider_id, kind = kind});
           append_err != nil {
            delete(provider_id, allocator)
            return nil, .Alloc_Failed
        }
    }

    return list, nil
}

credential_statuses_destroy :: proc(statuses: [dynamic]Credential_Status) {
    allocator := statuses.allocator
    assert(allocator.procedure != nil, "owned credential statuses carry their allocator")

    for status in statuses {
        delete(status.provider_id, allocator)
    }

    delete(statuses)
}

credentials_load :: proc(s: ^Store, allocator := context.allocator) -> (credentials: [dynamic]Credential, err: Error) {
    assert(s != nil, "credentials_load needs a store")
    assert(s.writer != nil, "an open store always holds its writer")
    assert(allocator.procedure != nil, "a credential read needs an allocator")

    st := sqlite.prepare(s.writer, CREDENTIALS_LOAD_SQL) or_return
    defer sqlite.finalize(st)

    list: [dynamic]Credential
    list.allocator = allocator
    defer if err != nil {
        credentials_destroy(list)
    }

    for {
        if has_row := sqlite.step_row(st) or_return; !has_row {
            break
        }

        credential := credential_read(st, allocator) or_return
        if _, append_err := append(&list, credential); append_err != nil {
            credential_destroy(&credential, allocator)
            return nil, .Alloc_Failed
        }
    }

    return list, nil
}

credential_api_key_upsert :: proc(s: ^Store, provider_id, api_key: string) -> Error {
    assert(s != nil, "credential_api_key_upsert needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    if !credential_provider_id_valid(provider_id) || !credential_secret_valid(api_key) {
        return .Invalid_Credential
    }

    return queries.upsert_api_key(&s.queries, {provider_id = provider_id, api_key = api_key})
}

credential_oauth_upsert :: proc(s: ^Store, provider_id: string, credentials: OAuth_Credential) -> Error {
    assert(s != nil, "credential_oauth_upsert needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    if !credential_provider_id_valid(provider_id) || !credential_oauth_valid(credentials) {
        return .Invalid_Credential
    }

    account_id: Maybe(string)
    if credentials.account_id != "" {
        account_id = credentials.account_id
    }

    return queries.upsert_oauth(
        &s.queries,
        {
            provider_id = provider_id,
            access_token = credentials.access_token,
            refresh_token = credentials.refresh_token,
            expires_at_ms = credentials.expires_at_ms,
            account_id = account_id,
        },
    )
}

credential_remove :: proc(s: ^Store, provider_id: string) -> (removed: bool, err: Error) {
    assert(s != nil, "credential_remove needs a store")
    assert(s.writer != nil, "an open store always holds its writer")

    if !credential_provider_id_valid(provider_id) {
        return false, .Invalid_Credential
    }

    queries.remove_credential(&s.queries, {provider_id = provider_id}) or_return
    changed := sqlite.changes(s.writer)
    assert(changed == 0 || changed == 1, "a provider id removes at most one credential")

    return changed == 1, nil
}

@(private)
credential_destroy :: proc(credentials: ^Credential, allocator := context.allocator) {
    assert(credentials != nil, "credential_destroy needs a value")

    delete(credentials.provider_id, allocator)
    secret.string_destroy(&credentials.api_key, allocator)
    secret.string_destroy(&credentials.access_token, allocator)
    secret.string_destroy(&credentials.refresh_token, allocator)
    secret.string_destroy(&credentials.account_id, allocator)
    credentials^ = {}
}

credentials_destroy :: proc(credentials: [dynamic]Credential) {
    allocator := credentials.allocator
    assert(allocator.procedure != nil, "owned credentials carry their allocator")

    for &value in credentials {
        credential_destroy(&value, allocator)
    }

    delete(credentials)
}

@(private)
credential_read :: proc(st: ^sqlite.Stmt, allocator: mem.Allocator) -> (credential: Credential, err: Error) {
    assert(st != nil, "credential_read needs a statement on a row")
    defer if err != nil {
        credential_destroy(&credential, allocator)
    }

    row: Credential_Row
    sqlite.scan_row(st, &row, allocator) or_return
    kind, valid := credential_kind_parse(row.kind)

    if !valid || !credential_provider_id_valid(row.provider_id) {
        return {}, .Invalid_Row
    }

    credential.provider_id = credential_clone(row.provider_id, allocator) or_return
    credential.kind = kind

    switch kind {
    case .Api_Key:
        api_key, has_api_key := row.api_key.?
        _, has_access := row.access_token.?
        _, has_refresh := row.refresh_token.?
        _, has_expiry := row.expires_at_ms.?
        _, has_account := row.account_id.?

        if !has_api_key ||
           has_access ||
           has_refresh ||
           has_expiry ||
           has_account ||
           !credential_secret_valid(api_key) {
            return credential, .Invalid_Row
        }

        credential.api_key = credential_clone(api_key, allocator) or_return

    case .OAuth:
        _, has_api_key := row.api_key.?
        access_token, has_access := row.access_token.?
        refresh_token, has_refresh := row.refresh_token.?
        expires_at_ms, has_expiry := row.expires_at_ms.?
        account_id, has_account := row.account_id.?

        oauth := OAuth_Credential {
            access_token  = access_token,
            refresh_token = refresh_token,
            expires_at_ms = expires_at_ms,
            account_id    = account_id,
        }
        if has_api_key ||
           !has_access ||
           !has_refresh ||
           !has_expiry ||
           (has_account && account_id == "") ||
           !credential_oauth_valid(oauth) {
            return credential, .Invalid_Row
        }

        credential.access_token = credential_clone(access_token, allocator) or_return
        credential.refresh_token = credential_clone(refresh_token, allocator) or_return
        credential.expires_at_ms = expires_at_ms
        if has_account {
            credential.account_id = credential_clone(account_id, allocator) or_return
        }
    }

    return credential, nil
}

@(private)
credential_clone :: proc(value: string, allocator: mem.Allocator) -> (owned: string, err: Error) {
    alloc_err: mem.Allocator_Error
    owned, alloc_err = strings.clone(value, allocator)
    if alloc_err != nil {
        return "", .Alloc_Failed
    }

    return owned, nil
}

@(private)
credential_provider_id_valid :: proc(provider_id: string) -> bool {
    if len(provider_id) == 0 || len(provider_id) > PROVIDER_ID_MAX_BYTES {
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

@(private)
credential_secret_valid :: proc(value: string) -> bool {
    return len(value) > 0 && len(value) <= CREDENTIAL_SECRET_MAX_BYTES
}

@(private)
credential_oauth_valid :: proc(credentials: OAuth_Credential) -> bool {
    return(
        credential_secret_valid(credentials.access_token) &&
        credential_secret_valid(credentials.refresh_token) &&
        credentials.expires_at_ms > 0 &&
        credentials.expires_at_ms <= CREDENTIAL_EXPIRES_AT_MS_MAX &&
        len(credentials.account_id) <= CREDENTIAL_ACCOUNT_ID_MAX_BYTES \
    )
}

@(private)
credential_kind_parse :: proc(value: string) -> (kind: Credential_Kind, valid: bool) {
    switch value {
    case "api_key":
        return .Api_Key, true
    case "oauth":
        return .OAuth, true
    }

    return {}, false
}
