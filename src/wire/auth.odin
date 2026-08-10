package wire

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
    return enum_from_wire(auth_flow_wire, value)
}

// Coarse persisted authentication state for a provider.
Auth_State :: enum {
    // No durable credentials are available.
    Signed_Out,

    // Durable credentials are available.
    Signed_In,
}

@(rodata)
auth_state_wire := [Auth_State]string {
    .Signed_Out = "signed_out",
    .Signed_In  = "signed_in",
}

// Wire string for an auth state.
auth_state_to_wire :: proc(state: Auth_State) -> string {
    return auth_state_wire[state]
}

// Auth state for a wire string; ok is false for an unknown state.
auth_state_from_wire :: proc(value: string) -> (Auth_State, bool) {
    return enum_from_wire(auth_state_wire, value)
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
    provider_id:   Provider_Id,

    // Whether durable credentials are available.
    state:         Auth_State,

    // @bounded LIMITS.max_auth_flows
    // Login mechanisms currently supported by this provider.
    login_flows:   []Auth_Flow,

    // @required-nullable
    // Current daemon-owned attempt, if one is running.
    pending_login: Maybe(Auth_Login_Summary),
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
auth_login_summary_emit :: proc(e: ^Emitter, self: Auth_Login_Summary) {
    object_begin(e)
    field_id(e, "login_id", ([32]u8)(self.login_id))
    field_string(e, "flow", auth_flow_to_wire(self.flow))
    object_end(e)
}

// Verify a public login summary.
auth_login_summary_validate :: proc(self: Auth_Login_Summary) -> Validation_Error {
    return enforce_id(([32]u8)(self.login_id))
}

// Write public provider auth state.
auth_provider_emit :: proc(e: ^Emitter, self: Auth_Provider) {
    object_begin(e)
    field_string(e, "provider_id", self.provider_id)
    field_string(e, "state", auth_state_to_wire(self.state))
    key(e, "login_flows")
    array_begin(e)
    for flow in self.login_flows {
        elem(e)
        val_string(e, auth_flow_to_wire(flow))
    }

    array_end(e)
    key(e, "pending_login")

    if login, ok := self.pending_login.?; ok {
        auth_login_summary_emit(e, login)
    } else {
        val_null(e)
    }

    object_end(e)
}

// Verify public provider auth state and its closed capability list.
auth_provider_validate :: proc(self: Auth_Provider) -> Validation_Error {
    provider_id_validate(self.provider_id) or_return

    if len(self.login_flows) == 0 || len(self.login_flows) > LIMITS.max_auth_flows {
        return .Overflow
    }

    seen: bit_set[Auth_Flow]
    for flow in self.login_flows {
        if flow in seen {
            return .Mismatched_Payload
        }
        seen += {flow}
    }

    if login, ok := self.pending_login.?; ok {
        auth_login_summary_validate(login) or_return

        if login.flow not_in seen {
            return .Mismatched_Payload
        }
    }

    return .None
}

// Deep-copy public provider auth state into `allocator`.
auth_provider_clone :: proc(self: Auth_Provider, allocator := context.allocator) -> Auth_Provider {
    flows := make([]Auth_Flow, len(self.login_flows), allocator)
    copy(flows, self.login_flows)

    return Auth_Provider {
        provider_id = strings.clone(self.provider_id, allocator),
        state = self.state,
        login_flows = flows,
        pending_login = self.pending_login,
    }
}

// Write auth.login params.
auth_login_params_emit :: proc(e: ^Emitter, self: Auth_Login_Params) {
    object_begin(e)
    field_string(e, "provider_id", self.provider_id)
    field_string(e, "flow", auth_flow_to_wire(self.flow))
    object_end(e)
}

// Verify auth.login params.
auth_login_params_validate :: proc(self: Auth_Login_Params) -> Validation_Error {
    return provider_id_validate(self.provider_id)
}

// Write an internally-tagged auth.login result.
auth_login_result_emit :: proc(e: ^Emitter, self: Auth_Login_Result) {
    object_begin(e)

    switch result in self {
    case Auth_Login_Result_Browser:
        field_string(e, "type", "browser")
        field_id(e, "login_id", ([32]u8)(result.login_id))
        field_string(e, "auth_url", result.auth_url)

    case Auth_Login_Result_Device_Code:
        field_string(e, "type", "device_code")
        field_id(e, "login_id", ([32]u8)(result.login_id))
        field_string(e, "verification_url", result.verification_url)
        field_string(e, "user_code", result.user_code)
    }

    object_end(e)
}

// Verify auth.login result bounds.
auth_login_result_validate :: proc(self: Auth_Login_Result) -> Validation_Error {
    switch result in self {
    case Auth_Login_Result_Browser:
        enforce_id(([32]u8)(result.login_id)) or_return

        if result.auth_url == "" {
            return .Invalid_Length
        }

        return enforce_bounded(LIMITS.max_auth_url_bytes, result.auth_url)

    case Auth_Login_Result_Device_Code:
        enforce_id(([32]u8)(result.login_id)) or_return

        if result.verification_url == "" || result.user_code == "" {
            return .Invalid_Length
        }

        enforce_bounded(LIMITS.max_auth_url_bytes, result.verification_url) or_return

        return enforce_bounded(LIMITS.max_auth_user_code_bytes, result.user_code)
    }

    return .None
}

// Write auth.cancel_login params.
auth_cancel_login_params_emit :: proc(e: ^Emitter, self: Auth_Cancel_Login_Params) {
    object_begin(e)
    field_id(e, "login_id", ([32]u8)(self.login_id))
    object_end(e)
}

// Verify auth.cancel_login params.
auth_cancel_login_params_validate :: proc(self: Auth_Cancel_Login_Params) -> Validation_Error {
    return enforce_id(([32]u8)(self.login_id))
}

// Write auth.logout params.
auth_logout_params_emit :: proc(e: ^Emitter, self: Auth_Logout_Params) {
    object_begin(e)
    field_string(e, "provider_id", self.provider_id)
    object_end(e)
}

// Verify auth.logout params.
auth_logout_params_validate :: proc(self: Auth_Logout_Params) -> Validation_Error {
    return provider_id_validate(self.provider_id)
}

// Write auth.list result.
auth_list_result_emit :: proc(e: ^Emitter, self: Auth_List_Result) {
    object_begin(e)
    key(e, "providers")
    array_begin(e)
    for provider in self.providers {
        elem(e)
        auth_provider_emit(e, provider)
    }

    array_end(e)
    object_end(e)
}

// Verify auth.list result.
auth_list_result_validate :: proc(self: Auth_List_Result) -> Validation_Error {
    if len(self.providers) > LIMITS.max_auth_providers {
        return .Overflow
    }

    for provider in self.providers {
        auth_provider_validate(provider) or_return
    }

    return .None
}

// Write a terminal login outcome.
auth_login_outcome_emit :: proc(e: ^Emitter, self: Auth_Login_Outcome) {
    object_begin(e)

    switch outcome in self {
    case Auth_Login_Outcome_Succeeded:
        field_string(e, "type", "succeeded")

    case Auth_Login_Outcome_Canceled:
        field_string(e, "type", "canceled")

    case Auth_Login_Outcome_Failed:
        field_string(e, "type", "failed")
        field_string(e, "message", outcome.message)
    }

    object_end(e)
}

// Verify a terminal login outcome.
auth_login_outcome_validate :: proc(self: Auth_Login_Outcome) -> Validation_Error {
    #partial switch outcome in self {
    case Auth_Login_Outcome_Failed:
        if outcome.message == "" {
            return .Invalid_Length
        }

        return enforce_bounded(LIMITS.max_error_message_bytes, outcome.message)
    }

    return .None
}

// Write auth.login_finished payload.
auth_login_finished_data_emit :: proc(e: ^Emitter, self: Auth_Login_Finished_Data) {
    object_begin(e)
    field_id(e, "login_id", ([32]u8)(self.login_id))
    field_string(e, "provider_id", self.provider_id)
    key(e, "outcome")
    auth_login_outcome_emit(e, self.outcome)
    object_end(e)
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
auth_changed_data_emit :: proc(e: ^Emitter, self: Auth_Changed_Data) {
    object_begin(e)
    key(e, "provider")
    auth_provider_emit(e, self.provider)
    object_end(e)
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
auth_login_summary_from_reader :: proc(d: ^Decoder) -> (summary: Auth_Login_Summary, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Login,
        Flow,
    }

    seen: bit_set[Field]
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "login_id":
            summary.login_id = Login_Id(dec_fixed(d, 32) or_return)
            seen += {.Login}

        case "flow":
            summary.flow = dec_enum(d, auth_flow_wire) or_return
            seen += {.Flow}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Login, .Flow} {
        return {}, .Mismatched_Payload
    }

    return summary, .None
}

// Decode public provider auth state.
auth_provider_from_reader :: proc(d: ^Decoder) -> (provider: Auth_Provider, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Provider,
        State,
        Flows,
        Pending,
    }

    seen: bit_set[Field]
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            provider.provider_id = dec_string(d) or_return
            seen += {.Provider}

        case "state":
            provider.state = dec_enum(d, auth_state_wire) or_return
            seen += {.State}

        case "login_flows":
            provider.login_flows = dec_array(d, auth_flow_from_reader) or_return
            seen += {.Flows}

        case "pending_login":
            seen += {.Pending}

            if !dec_is_null(d) {
                provider.pending_login = auth_login_summary_from_reader(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Provider, .State, .Flows, .Pending} {
        return {}, .Mismatched_Payload
    }

    return provider, .None
}

// Decode auth.login params.
auth_login_params_from_reader :: proc(d: ^Decoder) -> (params: Auth_Login_Params, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Provider,
        Flow,
    }

    seen: bit_set[Field]
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            params.provider_id = dec_string(d) or_return
            seen += {.Provider}

        case "flow":
            params.flow = dec_enum(d, auth_flow_wire) or_return
            seen += {.Flow}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Provider, .Flow} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode an internally-tagged auth.login result.
auth_login_result_from_reader :: proc(d: ^Decoder) -> (result: Auth_Login_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "browser":
        value: Auth_Login_Result_Browser

        Field :: enum {
            Login,
            Url,
        }

        seen: bit_set[Field]
        for {
            field, done := dec_key(d) or_return
            if done do break

            switch field {
            case "login_id":
                value.login_id = Login_Id(dec_fixed(d, 32) or_return)
                seen += {.Login}

            case "auth_url":
                value.auth_url = dec_string(d) or_return
                seen += {.Url}

            case "verification_url", "user_code":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Login, .Url} {
            return nil, .Mismatched_Payload
        }

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
            field, done := dec_key(d) or_return
            if done do break

            switch field {
            case "login_id":
                value.login_id = Login_Id(dec_fixed(d, 32) or_return)
                seen += {.Login}

            case "verification_url":
                value.verification_url = dec_string(d) or_return
                seen += {.Url}

            case "user_code":
                value.user_code = dec_string(d) or_return
                seen += {.Code}

            case "auth_url":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Login, .Url, .Code} {
            return nil, .Mismatched_Payload
        }

        return value, .None
    }

    return nil, .Mismatched_Payload
}

// Decode auth.cancel_login params.
auth_cancel_login_params_from_reader :: proc(
    d: ^Decoder,
) -> (
    params: Auth_Cancel_Login_Params,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return
    have := false
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "login_id":
            params.login_id = Login_Id(dec_fixed(d, 32) or_return)
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode auth.logout params.
auth_logout_params_from_reader :: proc(d: ^Decoder) -> (params: Auth_Logout_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "provider_id":
            params.provider_id = dec_string(d) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode auth.list result.
auth_list_result_from_reader :: proc(d: ^Decoder) -> (result: Auth_List_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "providers":
            result.providers = dec_array(d, auth_provider_from_reader) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode a terminal login outcome.
auth_login_outcome_from_reader :: proc(d: ^Decoder) -> (outcome: Auth_Login_Outcome, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "succeeded", "canceled":
        for {
            field, done := dec_key(d) or_return
            if done do break

            if field == "message" {
                return nil, .Mismatched_Payload
            }
            dec_skip(d) or_return
        }

        if tag == "succeeded" {
            return Auth_Login_Outcome_Succeeded{}, .None
        }

        return Auth_Login_Outcome_Canceled{}, .None

    case "failed":
        message := ""
        have := false
        for {
            field, done := dec_key(d) or_return
            if done do break

            switch field {
            case "message":
                message = dec_string(d) or_return
                have = true

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Auth_Login_Outcome_Failed{message = message}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode auth.login_finished payload.
auth_login_finished_data_from_reader :: proc(d: ^Decoder) -> (data: Auth_Login_Finished_Data, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Login,
        Provider,
        Outcome,
    }

    seen: bit_set[Field]
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "login_id":
            data.login_id = Login_Id(dec_fixed(d, 32) or_return)
            seen += {.Login}

        case "provider_id":
            data.provider_id = dec_string(d) or_return
            seen += {.Provider}

        case "outcome":
            data.outcome = auth_login_outcome_from_reader(d) or_return
            seen += {.Outcome}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Login, .Provider, .Outcome} {
        return {}, .Mismatched_Payload
    }

    return data, .None
}

// Decode auth.changed payload.
auth_changed_data_from_reader :: proc(d: ^Decoder) -> (data: Auth_Changed_Data, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        field, done := dec_key(d) or_return
        if done do break

        switch field {
        case "provider":
            data.provider = auth_provider_from_reader(d) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return data, .None
}

@(private)
provider_id_validate :: proc(provider_id: Provider_Id) -> Validation_Error {
    enforce_bounded(64, provider_id) or_return

    if len(provider_id) == 0 {
        return .Invalid_Length
    }

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
auth_flow_from_reader :: proc(d: ^Decoder) -> (flow: Auth_Flow, err: Validation_Error) {
    return dec_enum(d, auth_flow_wire)
}
