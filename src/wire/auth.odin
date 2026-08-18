package wire
import "libs:json"

import "core:strings"

// @bounded 64
// Stable provider identifier used by auth and catalog configuration.
Provider_Id :: string

// OAuth login mechanisms a provider exposes.
Auth_Flow :: enum {
    // Authorization-code login using a loopback browser callback.
    Browser,

    // Device authorization login using a verification page and user code.
    Device_Code,
}

@(rodata)
auth_flow_wire := [Auth_Flow]string {
    .Browser     = "browser",
    .Device_Code = "device_code",
}

// Wire string for an auth flow.
auth_flow_to_wire :: proc(flow: Auth_Flow) -> string {
    return auth_flow_wire[flow]
}

// Auth flow for a wire string; ok is false for an unknown flow.
auth_flow_from_wire :: proc(value: string) -> (Auth_Flow, bool) {
    return json.enum_from_wire(auth_flow_wire, value)
}

// Kind of durable provider credential. Values reveal no credential material.
Auth_Credential_Kind :: enum {
    Api_Key,
    OAuth,
}

@(rodata)
auth_credential_kind_wire := [Auth_Credential_Kind]string {
    .Api_Key = "api_key",
    .OAuth   = "oauth",
}

// Wire string for a credential kind.
auth_credential_kind_to_wire :: proc(kind: Auth_Credential_Kind) -> string {
    return auth_credential_kind_wire[kind]
}

// Public locator for one daemon-owned login attempt. It contains no OAuth secret.
Auth_Login_Summary :: struct {
    // Daemon-minted login attempt id.
    login_id: Login_Id,

    // Mechanism used by the attempt.
    flow:     Auth_Flow,
}

// Public authentication state and capabilities for one provider.
Auth_Provider :: struct {
    // Stable configuration identifier.
    provider_id:      Provider_Id,

    // @required-nullable
    // Durable credential kind, or null when none is saved.
    credential_kind:  Maybe(Auth_Credential_Kind),

    // Whether API-key storage changed after this daemon started.
    restart_required: bool,

    // @bounded LIMITS.max_auth_flows
    // Login mechanisms currently supported by this provider.
    login_flows:      []Auth_Flow,

    // @required-nullable
    // Current daemon-owned attempt, if one is running.
    pending_login:    Maybe(Auth_Login_Summary),
}

// Params for `auth.login`.
Auth_Login_Params :: struct {
    // Provider to authenticate.
    provider_id: Provider_Id,

    // Requested login mechanism.
    flow:        Auth_Flow,
}

// Browser authorization details returned only to the requesting connection.
Auth_Login_Result_Browser :: struct {
    // Daemon-owned attempt id.
    login_id: Login_Id,

    // @bounded LIMITS.max_auth_url_bytes
    // Authorization URL to open in a browser.
    auth_url: string,
}

// Device authorization details returned only to the requesting connection.
Auth_Login_Result_Device_Code :: struct {
    // Daemon-owned attempt id.
    login_id:         Login_Id,

    // @bounded LIMITS.max_auth_url_bytes
    // Page where the user enters `user_code`.
    verification_url: string,

    // @bounded LIMITS.max_auth_user_code_bytes
    // Short-lived code entered by the user, not the provider's device machine code.
    user_code:        string,
}

// Result of `auth.login`, tagged by the mechanism actually started.
Auth_Login_Result :: union {
    Auth_Login_Result_Browser,
    Auth_Login_Result_Device_Code,
}

// Params for `auth.cancel_login`.
Auth_Cancel_Login_Params :: struct {
    // Daemon-owned attempt to cancel.
    login_id: Login_Id,
}

// Params for `auth.logout`.
Auth_Logout_Params :: struct {
    // Provider whose durable credentials are removed.
    provider_id: Provider_Id,
}

// Write-only params for `auth.set_api_key`. The key is never returned or retained by wire state.
Auth_Set_Api_Key_Params :: struct {
    // Provider whose durable API key is replaced.
    provider_id: Provider_Id,

    // @bounded LIMITS.max_api_key_bytes
    // Secret key accepted only in this request.
    api_key:     string,
}

// Result of staging an API-key replacement.
Auth_Set_Api_Key_Result :: struct {
    // Always true: a running daemon does not change its active credential snapshot.
    restart_required: bool,
}

// Result of `auth.list`.
Auth_List_Result :: struct {
    // @bounded LIMITS.max_auth_providers
    // Authentication-capable providers known to the daemon.
    providers: []Auth_Provider,
}

// Login completed successfully and credentials were durably stored.
Auth_Login_Outcome_Succeeded :: struct {}

// Login was explicitly canceled.
Auth_Login_Outcome_Canceled :: struct {}

// Login failed without changing durable credentials.
Auth_Login_Outcome_Failed :: struct {
    // @bounded LIMITS.max_error_message_bytes
    // Human-readable failure detail with no credential material.
    message: string,
}

// Terminal outcome for a daemon-owned login attempt.
Auth_Login_Outcome :: union {
    Auth_Login_Outcome_Succeeded,
    Auth_Login_Outcome_Canceled,
    Auth_Login_Outcome_Failed,
}

// Payload for `auth.login_finished`.
Auth_Login_Finished_Data :: struct {
    // Completed daemon-owned attempt.
    login_id:    Login_Id,

    // Provider the attempt targeted.
    provider_id: Provider_Id,

    // Terminal outcome.
    outcome:     Auth_Login_Outcome,
}

// Payload for `auth.changed`.
Auth_Changed_Data :: struct {
    // Complete current public provider state.
    provider: Auth_Provider,
}

// Write a public login summary.
auth_login_summary_emit :: proc(e: ^json.Emitter, self: Auth_Login_Summary) {
    json.object_begin(e)
    json.field_id(e, "login_id", ([32]u8)(self.login_id))
    json.field_string(e, "flow", auth_flow_to_wire(self.flow))
    json.object_end(e)
}

// Verify a public login summary.
auth_login_summary_validate :: proc(self: Auth_Login_Summary) -> Validation_Error {
    return enforce_id(([32]u8)(self.login_id))
}

// Write public provider auth state.
auth_provider_emit :: proc(e: ^json.Emitter, self: Auth_Provider) {
    json.object_begin(e)
    json.field_string(e, "provider_id", self.provider_id)
    json.key(e, "credential_kind")

    if kind, ok := self.credential_kind.?; ok {
        json.val_string(e, auth_credential_kind_to_wire(kind))
    } else {
        json.val_null(e)
    }

    json.field_bool(e, "restart_required", self.restart_required)
    json.key(e, "login_flows")
    json.array_begin(e)
    for flow in self.login_flows {
        json.elem(e)
        json.val_string(e, auth_flow_to_wire(flow))
    }

    json.array_end(e)
    json.key(e, "pending_login")

    if login, ok := self.pending_login.?; ok {
        auth_login_summary_emit(e, login)
    } else {
        json.val_null(e)
    }

    json.object_end(e)
}

// Verify public provider auth state and its closed capability list.
auth_provider_validate :: proc(self: Auth_Provider) -> Validation_Error {
    provider_id_validate(self.provider_id) or_return

    if len(self.login_flows) > LIMITS.max_auth_flows do return .Overflow

    seen: bit_set[Auth_Flow]
    for flow in self.login_flows {
        if flow in seen do return .Mismatched_Payload
        seen += {flow}
    }

    if login, ok := self.pending_login.?; ok {
        auth_login_summary_validate(login) or_return

        if login.flow not_in seen do return .Mismatched_Payload
    }

    return .None
}

// Deep-copy public provider auth state into `allocator`.
auth_provider_clone :: proc(self: Auth_Provider, allocator := context.allocator) -> Auth_Provider {
    flows := make([]Auth_Flow, len(self.login_flows), allocator)
    copy(flows, self.login_flows)

    return Auth_Provider {
        provider_id = strings.clone(self.provider_id, allocator),
        credential_kind = self.credential_kind,
        restart_required = self.restart_required,
        login_flows = flows,
        pending_login = self.pending_login,
    }
}

// Write auth.login params.
auth_login_params_emit :: proc(e: ^json.Emitter, self: Auth_Login_Params) {
    json.object_begin(e)
    json.field_string(e, "provider_id", self.provider_id)
    json.field_string(e, "flow", auth_flow_to_wire(self.flow))
    json.object_end(e)
}

// Verify auth.login params.
auth_login_params_validate :: proc(self: Auth_Login_Params) -> Validation_Error {
    return provider_id_validate(self.provider_id)
}

// Write an internally-tagged auth.login result.
auth_login_result_emit :: proc(e: ^json.Emitter, self: Auth_Login_Result) {
    json.object_begin(e)

    switch result in self {
    case Auth_Login_Result_Browser:
        json.field_string(e, "type", "browser")
        json.field_id(e, "login_id", ([32]u8)(result.login_id))
        json.field_string(e, "auth_url", result.auth_url)

    case Auth_Login_Result_Device_Code:
        json.field_string(e, "type", "device_code")
        json.field_id(e, "login_id", ([32]u8)(result.login_id))
        json.field_string(e, "verification_url", result.verification_url)
        json.field_string(e, "user_code", result.user_code)
    }

    json.object_end(e)
}

// Verify auth.login result bounds.
auth_login_result_validate :: proc(self: Auth_Login_Result) -> Validation_Error {
    switch result in self {
    case Auth_Login_Result_Browser:
        enforce_id(([32]u8)(result.login_id)) or_return

        if result.auth_url == "" do return .Invalid_Length

        return enforce_bounded(LIMITS.max_auth_url_bytes, result.auth_url)

    case Auth_Login_Result_Device_Code:
        enforce_id(([32]u8)(result.login_id)) or_return

        if result.verification_url == "" || result.user_code == "" do return .Invalid_Length

        enforce_bounded(LIMITS.max_auth_url_bytes, result.verification_url) or_return

        return enforce_bounded(LIMITS.max_auth_user_code_bytes, result.user_code)
    }

    return .None
}

// Write auth.cancel_login params.
auth_cancel_login_params_emit :: proc(e: ^json.Emitter, self: Auth_Cancel_Login_Params) {
    json.object_begin(e)
    json.field_id(e, "login_id", ([32]u8)(self.login_id))
    json.object_end(e)
}

// Verify auth.cancel_login params.
auth_cancel_login_params_validate :: proc(self: Auth_Cancel_Login_Params) -> Validation_Error {
    return enforce_id(([32]u8)(self.login_id))
}

// Write auth.logout params.
auth_logout_params_emit :: proc(e: ^json.Emitter, self: Auth_Logout_Params) {
    json.object_begin(e)
    json.field_string(e, "provider_id", self.provider_id)
    json.object_end(e)
}

// Verify auth.logout params.
auth_logout_params_validate :: proc(self: Auth_Logout_Params) -> Validation_Error {
    return provider_id_validate(self.provider_id)
}

// Write auth.set_api_key params. This is the only request emitter that accepts a provider secret.
auth_set_api_key_params_emit :: proc(e: ^json.Emitter, self: Auth_Set_Api_Key_Params) {
    assert(e.secret, "auth.set_api_key needs a secret emitter")

    json.object_begin(e)
    json.field_string(e, "provider_id", self.provider_id)
    json.field_string(e, "api_key", self.api_key)
    json.object_end(e)
}

// Verify auth.set_api_key params before any durable mutation.
auth_set_api_key_params_validate :: proc(self: Auth_Set_Api_Key_Params) -> Validation_Error {
    provider_id_validate(self.provider_id) or_return

    if self.api_key == "" do return .Invalid_Length

    return enforce_bounded(LIMITS.max_api_key_bytes, self.api_key)
}

// Write the secret-free auth.set_api_key result.
auth_set_api_key_result_emit :: proc(e: ^json.Emitter, self: Auth_Set_Api_Key_Result) {
    json.object_begin(e)
    json.field_bool(e, "restart_required", self.restart_required)
    json.object_end(e)
}

// A running daemon always requires restart after accepting a key.
auth_set_api_key_result_validate :: proc(self: Auth_Set_Api_Key_Result) -> Validation_Error {
    if !self.restart_required do return .Mismatched_Payload

    return .None
}

// Write auth.list result.
auth_list_result_emit :: proc(e: ^json.Emitter, self: Auth_List_Result) {
    json.object_begin(e)
    json.key(e, "providers")
    json.array_begin(e)
    for provider in self.providers {
        json.elem(e)
        auth_provider_emit(e, provider)
    }

    json.array_end(e)
    json.object_end(e)
}

// Verify auth.list result.
auth_list_result_validate :: proc(self: Auth_List_Result) -> Validation_Error {
    if len(self.providers) > LIMITS.max_auth_providers do return .Overflow

    for provider in self.providers {
        auth_provider_validate(provider) or_return
    }

    return .None
}

// Write a terminal login outcome.
auth_login_outcome_emit :: proc(e: ^json.Emitter, self: Auth_Login_Outcome) {
    json.object_begin(e)

    switch outcome in self {
    case Auth_Login_Outcome_Succeeded:
        json.field_string(e, "type", "succeeded")

    case Auth_Login_Outcome_Canceled:
        json.field_string(e, "type", "canceled")

    case Auth_Login_Outcome_Failed:
        json.field_string(e, "type", "failed")
        json.field_string(e, "message", outcome.message)
    }

    json.object_end(e)
}

// Verify a terminal login outcome.
auth_login_outcome_validate :: proc(self: Auth_Login_Outcome) -> Validation_Error {
    #partial switch outcome in self {
    case Auth_Login_Outcome_Failed:
        if outcome.message == "" do return .Invalid_Length

        return enforce_bounded(LIMITS.max_error_message_bytes, outcome.message)
    }

    return .None
}

// Write auth.login_finished payload.
auth_login_finished_data_emit :: proc(e: ^json.Emitter, self: Auth_Login_Finished_Data) {
    json.object_begin(e)
    json.field_id(e, "login_id", ([32]u8)(self.login_id))
    json.field_string(e, "provider_id", self.provider_id)
    json.key(e, "outcome")
    auth_login_outcome_emit(e, self.outcome)
    json.object_end(e)
}

// Verify auth.login_finished payload.
auth_login_finished_data_validate :: proc(self: Auth_Login_Finished_Data) -> Validation_Error {
    enforce_id(([32]u8)(self.login_id)) or_return
    provider_id_validate(self.provider_id) or_return

    return auth_login_outcome_validate(self.outcome)
}

// Deep-copy auth.login_finished payload into `allocator`.
auth_login_finished_data_clone :: proc(
    self: Auth_Login_Finished_Data,
    allocator := context.allocator,
) -> Auth_Login_Finished_Data {
    outcome: Auth_Login_Outcome

    switch value in self.outcome {
    case Auth_Login_Outcome_Succeeded:
        outcome = value

    case Auth_Login_Outcome_Canceled:
        outcome = value

    case Auth_Login_Outcome_Failed:
        outcome = Auth_Login_Outcome_Failed {
            message = strings.clone(value.message, allocator),
        }
    }

    return {login_id = self.login_id, provider_id = strings.clone(self.provider_id, allocator), outcome = outcome}
}

// Write auth.changed payload.
auth_changed_data_emit :: proc(e: ^json.Emitter, self: Auth_Changed_Data) {
    json.object_begin(e)
    json.key(e, "provider")
    auth_provider_emit(e, self.provider)
    json.object_end(e)
}

// Verify auth.changed payload.
auth_changed_data_validate :: proc(self: Auth_Changed_Data) -> Validation_Error {
    return auth_provider_validate(self.provider)
}

// Deep-copy auth.changed payload into `allocator`.
auth_changed_data_clone :: proc(self: Auth_Changed_Data, allocator := context.allocator) -> Auth_Changed_Data {
    return {provider = auth_provider_clone(self.provider, allocator)}
}

// Decode a public login summary.
auth_login_summary_from_reader :: proc(d: ^json.Decoder) -> (summary: Auth_Login_Summary, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Login,
        Flow,
    }

    seen: bit_set[Field]
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "login_id":
            summary.login_id = Login_Id(json.dec_fixed(d, 32) or_return)
            seen += {.Login}

        case "flow":
            summary.flow = json.dec_enum(d, auth_flow_wire) or_return
            seen += {.Flow}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Login, .Flow} do return {}, .Mismatched_Payload

    return summary, .None
}

// Decode public provider auth state.
auth_provider_from_reader :: proc(d: ^json.Decoder) -> (provider: Auth_Provider, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Provider,
        Credential,
        Restart,
        Flows,
        Pending,
    }

    seen: bit_set[Field]
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            provider.provider_id = json.dec_string(d) or_return
            seen += {.Provider}

        case "credential_kind":
            seen += {.Credential}

            if !json.dec_is_null(d) do provider.credential_kind = json.dec_enum(d, auth_credential_kind_wire) or_return

        case "restart_required":
            provider.restart_required = json.dec_bool(d) or_return
            seen += {.Restart}

        case "login_flows":
            provider.login_flows = json.dec_array(d, auth_flow_from_reader) or_return
            seen += {.Flows}

        case "pending_login":
            seen += {.Pending}

            if !json.dec_is_null(d) do provider.pending_login = auth_login_summary_from_reader(d) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Provider, .Credential, .Restart, .Flows, .Pending} do return {}, .Mismatched_Payload

    return provider, .None
}

// Decode auth.login params.
auth_login_params_from_reader :: proc(d: ^json.Decoder) -> (params: Auth_Login_Params, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Provider,
        Flow,
    }

    seen: bit_set[Field]
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            params.provider_id = json.dec_string(d) or_return
            seen += {.Provider}

        case "flow":
            params.flow = json.dec_enum(d, auth_flow_wire) or_return
            seen += {.Flow}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Provider, .Flow} do return {}, .Mismatched_Payload

    return params, .None
}

// Decode an internally-tagged auth.login result.
auth_login_result_from_reader :: proc(d: ^json.Decoder) -> (result: Auth_Login_Result, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    tag := json.dec_find_tag(d, "type") or_return

    switch tag {
    case "browser":
        value: Auth_Login_Result_Browser

        Field :: enum {
            Login,
            Url,
        }

        seen: bit_set[Field]
        for {
            field, done := json.dec_key(d) or_return
            if done do break

            switch field {
            case "login_id":
                value.login_id = Login_Id(json.dec_fixed(d, 32) or_return)
                seen += {.Login}

            case "auth_url":
                value.auth_url = json.dec_string(d) or_return
                seen += {.Url}

            case "verification_url", "user_code":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if seen != {.Login, .Url} do return nil, .Mismatched_Payload

        return value, .None

    case "device_code":
        value: Auth_Login_Result_Device_Code

        Field :: enum {
            Login,
            Url,
            Code,
        }

        seen: bit_set[Field]
        for {
            field, done := json.dec_key(d) or_return
            if done do break

            switch field {
            case "login_id":
                value.login_id = Login_Id(json.dec_fixed(d, 32) or_return)
                seen += {.Login}

            case "verification_url":
                value.verification_url = json.dec_string(d) or_return
                seen += {.Url}

            case "user_code":
                value.user_code = json.dec_string(d) or_return
                seen += {.Code}

            case "auth_url":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if seen != {.Login, .Url, .Code} do return nil, .Mismatched_Payload

        return value, .None
    }

    return nil, .Mismatched_Payload
}

// Decode auth.cancel_login params.
auth_cancel_login_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Auth_Cancel_Login_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "login_id":
            params.login_id = Login_Id(json.dec_fixed(d, 32) or_return)
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return params, .None
}

// Decode auth.logout params.
auth_logout_params_from_reader :: proc(d: ^json.Decoder) -> (params: Auth_Logout_Params, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            params.provider_id = json.dec_string(d) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return params, .None
}

// Decode write-only auth.set_api_key params.
auth_set_api_key_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Auth_Set_Api_Key_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Provider,
        Key,
    }

    seen: bit_set[Field]
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            params.provider_id = json.dec_string(d) or_return
            seen += {.Provider}

        case "api_key":
            params.api_key = json.dec_string(d) or_return
            seen += {.Key}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Provider, .Key} do return {}, .Mismatched_Payload

    return params, .None
}

// Decode the secret-free auth.set_api_key result.
auth_set_api_key_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Auth_Set_Api_Key_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "restart_required":
            result.restart_required = json.dec_bool(d) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return result, .None
}

// Decode auth.list result.
auth_list_result_from_reader :: proc(d: ^json.Decoder) -> (result: Auth_List_Result, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "providers":
            result.providers = json.dec_array(d, auth_provider_from_reader) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return result, .None
}

// Decode a terminal login outcome.
auth_login_outcome_from_reader :: proc(d: ^json.Decoder) -> (outcome: Auth_Login_Outcome, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    tag := json.dec_find_tag(d, "type") or_return

    switch tag {
    case "succeeded", "canceled":
        for {
            field, done := json.dec_key(d) or_return
            if done do break

            if field == "message" do return nil, .Mismatched_Payload
            json.dec_skip(d) or_return
        }

        if tag == "succeeded" do return Auth_Login_Outcome_Succeeded{}, .None

        return Auth_Login_Outcome_Canceled{}, .None

    case "failed":
        message := ""
        have := false
        for {
            field, done := json.dec_key(d) or_return
            if done do break

            switch field {
            case "message":
                message = json.dec_string(d) or_return
                have = true

            case:
                json.dec_skip(d) or_return
            }
        }

        if !have do return nil, .Mismatched_Payload

        return Auth_Login_Outcome_Failed{message = message}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode auth.login_finished payload.
auth_login_finished_data_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    data: Auth_Login_Finished_Data,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Login,
        Provider,
        Outcome,
    }

    seen: bit_set[Field]
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "login_id":
            data.login_id = Login_Id(json.dec_fixed(d, 32) or_return)
            seen += {.Login}

        case "provider_id":
            data.provider_id = json.dec_string(d) or_return
            seen += {.Provider}

        case "outcome":
            data.outcome = auth_login_outcome_from_reader(d) or_return
            seen += {.Outcome}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Login, .Provider, .Outcome} do return {}, .Mismatched_Payload

    return data, .None
}

// Decode auth.changed payload.
auth_changed_data_from_reader :: proc(d: ^json.Decoder) -> (data: Auth_Changed_Data, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        field, done := json.dec_key(d) or_return
        if done do break

        switch field {
        case "provider":
            data.provider = auth_provider_from_reader(d) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return data, .None
}

// Verify the bounded lowercase identifier used by provider-scoped wire fields.
provider_id_validate :: proc(provider_id: Provider_Id) -> Validation_Error {
    enforce_bounded(64, provider_id) or_return

    if len(provider_id) == 0 do return .Invalid_Length

    for byte in transmute([]byte)provider_id {
        switch byte {
        case 'a' ..= 'z', '0' ..= '9', '-', '_', '.':
        case:
            return .Mismatched_Payload
        }
    }

    return .None
}

@(private)
auth_flow_from_reader :: proc(d: ^json.Decoder) -> (flow: Auth_Flow, err: json.Decode_Error) {
    return json.dec_enum(d, auth_flow_wire)
}
