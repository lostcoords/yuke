package wire

import "core:strings"
import "core:testing"

@(test)
test_auth_provider_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"provider_id":"openai-codex","state":"signed_out","login_flows":["browser","device_code"],"pending_login":{"login_id":"0123456789abcdef0123456789abcdef","flow":"browser"}}`
    decoder := decoder_init(input, context.temp_allocator)
    provider, err := auth_provider_from_reader(&decoder)
    testing.expect_value(t, err, Validation_Error.None)
    testing.expect_value(t, provider.provider_id, Provider_Id("openai-codex"))
    testing.expect_value(t, provider.state, Auth_State.Signed_Out)
    testing.expect_value(t, len(provider.login_flows), 2)
    login, pending := provider.pending_login.?
    testing.expect(t, pending, "pending login is present")
    testing.expect_value(t, login.flow, Auth_Flow.Browser)
    testing.expect_value(t, auth_provider_validate(provider), Validation_Error.None)

    emitter: Emitter
    emitter_init(&emitter)
    defer emitter_destroy(&emitter)
    auth_provider_emit(&emitter, provider)
    testing.expect_value(t, to_string(&emitter), input)
}

@(test)
test_auth_login_browser_result_is_order_independent :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"auth_url":"https://auth.example/start","login_id":"0123456789abcdef0123456789abcdef","type":"browser"}`
    decoder := decoder_init(input, context.temp_allocator)
    result, err := auth_login_result_from_reader(&decoder)
    testing.expect_value(t, err, Validation_Error.None)
    browser, ok := result.(Auth_Login_Result_Browser)
    testing.expect(t, ok, "browser result arm")
    testing.expect_value(t, browser.auth_url, "https://auth.example/start")
    testing.expect_value(t, auth_login_result_validate(result), Validation_Error.None)

    emitter: Emitter
    emitter_init(&emitter)
    defer emitter_destroy(&emitter)
    auth_login_result_emit(&emitter, result)
    testing.expect_value(
        t,
        to_string(&emitter),
        `{"type":"browser","login_id":"0123456789abcdef0123456789abcdef","auth_url":"https://auth.example/start"}`,
    )
}

@(test)
test_auth_login_result_rejects_cross_arm_fields :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"browser","login_id":"0123456789abcdef0123456789abcdef","auth_url":"https://auth.example/start","user_code":"ABCD-EFGH"}`
    decoder := decoder_init(input, context.temp_allocator)
    _, err := auth_login_result_from_reader(&decoder)
    testing.expect_value(t, err, Validation_Error.Mismatched_Payload)
}

@(test)
test_auth_provider_rejects_duplicate_or_unadvertised_flow :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    duplicate_input := `{"provider_id":"openai-codex","state":"signed_out","login_flows":["browser","browser"],"pending_login":null}`
    duplicate_decoder := decoder_init(duplicate_input, context.temp_allocator)
    duplicate, duplicate_err := auth_provider_from_reader(&duplicate_decoder)
    testing.expect_value(t, duplicate_err, Validation_Error.None)
    testing.expect_value(t, auth_provider_validate(duplicate), Validation_Error.Mismatched_Payload)

    unadvertised_input := `{"provider_id":"openai-codex","state":"signed_out","login_flows":["browser"],"pending_login":{"login_id":"0123456789abcdef0123456789abcdef","flow":"device_code"}}`
    unadvertised_decoder := decoder_init(unadvertised_input, context.temp_allocator)
    unadvertised, unadvertised_err := auth_provider_from_reader(&unadvertised_decoder)
    testing.expect_value(t, unadvertised_err, Validation_Error.None)
    testing.expect_value(t, auth_provider_validate(unadvertised), Validation_Error.Mismatched_Payload)
}

@(test)
test_auth_methods_roundtrip_without_credentials :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    params_input := `{"provider_id":"openai-codex","flow":"browser"}`
    params_decoder := decoder_init(params_input, context.temp_allocator)
    params, params_err := request_params_from_reader(.Auth_Login, &params_decoder)
    testing.expect_value(t, params_err, Validation_Error.None)
    testing.expect_value(t, request_params_validate(params), Validation_Error.None)

    params_emitter: Emitter
    emitter_init(&params_emitter)
    defer emitter_destroy(&params_emitter)
    request_params_emit(&params_emitter, params)
    testing.expect_value(t, to_string(&params_emitter), params_input)
    testing.expect(t, !strings.contains(to_string(&params_emitter), "token"), "wire params carry no credentials")

    list_input := `{"providers":[]}`
    list_decoder := decoder_init(list_input, context.temp_allocator)
    result, result_err := response_result_from_reader(.Auth_List, &list_decoder)
    testing.expect_value(t, result_err, Validation_Error.None)
    testing.expect_value(t, response_result_validate(result), Validation_Error.None)

    result_emitter: Emitter
    emitter_init(&result_emitter)
    defer emitter_destroy(&result_emitter)
    response_result_emit(&result_emitter, result)
    testing.expect_value(t, to_string(&result_emitter), list_input)
}

@(test)
test_auth_login_finished_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"login_id":"0123456789abcdef0123456789abcdef","provider_id":"openai-codex","outcome":{"message":"authorization denied","type":"failed"}}`
    decoder := decoder_init(input, context.temp_allocator)
    data, err := broadcast_data_from_reader(.Auth_Login_Finished, &decoder)
    testing.expect_value(t, err, Validation_Error.None)
    testing.expect_value(t, broadcast_data_validate(data), Validation_Error.None)
    testing.expect_value(t, broadcast_name_class(.Auth_Login_Finished), Broadcast_Class.Ungated)

    name, named := broadcast_data_name(data)
    testing.expect(t, named, "auth outcome names its broadcast")
    testing.expect_value(t, name, Broadcast_Name.Auth_Login_Finished)

    emitter: Emitter
    emitter_init(&emitter)
    defer emitter_destroy(&emitter)
    broadcast_data_emit(&emitter, data)
    testing.expect_value(
        t,
        to_string(&emitter),
        `{"login_id":"0123456789abcdef0123456789abcdef","provider_id":"openai-codex","outcome":{"type":"failed","message":"authorization denied"}}`,
    )
}
