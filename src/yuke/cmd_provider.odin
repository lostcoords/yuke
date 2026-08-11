package main

import "core:crypto"
import "core:fmt"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import client "src:client"
import daemon "src:daemon"
import "src:secret"
import term "src:term"
import wire "src:wire"

PROVIDER_REQUEST_TIMEOUT :: 10 * time.Second

Provider_Action :: enum {
    List,
    Set_Key,
    Remove_Key,
}

Provider_Options :: struct {
    action:      Provider_Action,
    provider_id: string,
}

Provider_State :: struct {
    action:      Provider_Action,
    provider_id: string,
    api_key:     string,
    client:      ^client.Client,
    stage:       int,
    failed:      bool,
    timed_out:   bool,
    done:        bool,
}

Provider_Prompt_Error :: enum {
    None,
    Terminal,
    Empty,
    Too_Long,
    Invalid_Utf8,
    Out_Of_Memory,
    Canceled,
}

provider_run :: proc() -> int {
    options, ok := provider_args_parse(os.args[2:])
    if !ok {
        fmt.eprintln("usage: yuke provider list | set-key <id> | remove-key <id>")
        return 2
    }

    if options.provider_id != "" &&
       wire.auth_logout_params_validate({provider_id = wire.Provider_Id(options.provider_id)}) != .None {
        fmt.eprintfln("yuke provider: invalid provider id %q", options.provider_id)
        return 2
    }

    state := Provider_State {
        action      = options.action,
        provider_id = options.provider_id,
    }
    defer secret.string_destroy(&state.api_key)

    if options.action == .Set_Key {
        prompt_err: Provider_Prompt_Error
        state.api_key, prompt_err = provider_key_prompt()
        if prompt_err != .None {
            provider_prompt_error_print(prompt_err)
            return prompt_err == .Canceled ? 130 : 1
        }
    }

    if err := nbio.acquire_thread_event_loop(); err != nil {
        fmt.eprintfln("yuke provider: event loop unavailable: %v", err)
        return 1
    }
    defer nbio.release_thread_event_loop()

    loop := nbio.current_thread_event_loop()
    transport, transport_err := client.ws_create(
        loop,
        {
            host = "127.0.0.1",
            port = daemon.DEFAULT_PORT,
            path = "/ws",
            max_frame_bytes = wire.LIMITS.max_frame_bytes,
            max_message_bytes = wire.LIMITS.max_frame_bytes,
        },
    )
    if transport_err != .None {
        fmt.eprintfln("yuke provider: could not prepare the daemon connection: %v", transport_err)
        return 1
    }

    c: client.Client
    state.client = &c
    open_err := client.client_open(
        &c,
        transport,
        "yuke-provider",
        DAEMON_VERSION,
        {on_ready = provider_on_ready, on_close = provider_on_close, on_error = provider_on_error},
        &state,
    )
    if open_err != .None {
        fmt.eprintfln("yuke provider: could not connect to the daemon: %v", open_err)
        return 1
    }

    timeout := nbio.timeout_poly(PROVIDER_REQUEST_TIMEOUT, &state, provider_on_timeout, loop)
    nbio.run_until(&state.done)
    if !state.timed_out {
        nbio.remove(timeout)
    }

    client.client_destroy(&c)
    if state.timed_out {
        fmt.eprintln("yuke provider: the daemon did not answer in time")
        return 1
    }
    if state.failed {
        return 1
    }

    return 0
}

provider_args_parse :: proc(args: []string) -> (options: Provider_Options, ok: bool) {
    if len(args) == 1 && args[0] == "list" {
        return {action = .List}, true
    }
    if len(args) == 2 && args[0] == "set-key" {
        return {action = .Set_Key, provider_id = args[1]}, true
    }
    if len(args) == 2 && args[0] == "remove-key" {
        return {action = .Remove_Key, provider_id = args[1]}, true
    }

    return {}, false
}

provider_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    state := (^Provider_State)(c.user_data)
    send_err: client.Protocol_Error

    switch state.action {
    case .List, .Remove_Key:
        _, send_err = client.client_send_request(c, .Auth_List, wire.Empty{}, provider_on_response)

    case .Set_Key:
        _, send_err = client.client_send_request(
            c,
            .Auth_Set_Api_Key,
            wire.Auth_Set_Api_Key_Params{provider_id = wire.Provider_Id(state.provider_id), api_key = state.api_key},
            provider_on_response,
        )
        secret.string_destroy(&state.api_key)
    }

    if send_err != .None {
        fmt.eprintfln("yuke provider: request could not be sent: %v", send_err)
        state.failed = true
        client.client_close(c)
    }
}

provider_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    state := (^Provider_State)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        state.failed = true
        return
    }

    switch response in answered.response {
    case wire.Response_Error:
        fmt.eprintfln("yuke provider: daemon rejected the request: %s", response.error.message)
        state.failed = true

    case wire.Response_Ok:
        if provider_response_apply(c, response.result, state) {
            return
        }
    }

    client.client_close(c)
}

provider_response_apply :: proc(c: ^client.Client, result: wire.Response_Result, state: ^Provider_State) -> bool {
    switch state.action {
    case .List:
        listed := result.(wire.Auth_List_Result)
        provider_list_print(listed.providers)

    case .Set_Key:
        saved := result.(wire.Auth_Set_Api_Key_Result)
        assert(saved.restart_required, "API-key write result must require restart")
        fmt.printfln("saved API key for %s; restart yuked to apply it", state.provider_id)

    case .Remove_Key:
        if state.stage == 0 {
            listed := result.(wire.Auth_List_Result)
            for provider in listed.providers {
                if provider.provider_id != wire.Provider_Id(state.provider_id) {
                    continue
                }

                if len(provider.login_flows) > 0 {
                    fmt.eprintfln("yuke provider: %s uses OAuth; remove-key cannot log it out", state.provider_id)
                    state.failed = true
                    return false
                }
                break
            }

            state.stage = 1
            _, send_err := client.client_send_request(
                c,
                .Auth_Logout,
                wire.Auth_Logout_Params{provider_id = wire.Provider_Id(state.provider_id)},
                provider_on_response,
            )
            if send_err != .None {
                fmt.eprintfln("yuke provider: removal could not be sent: %v", send_err)
                state.failed = true
                return false
            }

            return true
        }

        _ = result.(wire.Empty)
        fmt.printfln(
            "removed saved API key for %s; a running daemon may retain the previous key until restart",
            state.provider_id,
        )
    }

    return false
}

provider_list_print :: proc(providers: []wire.Auth_Provider) {
    fmt.println("PROVIDER\tCREDENTIAL\tSTATE")
    for provider in providers {
        credential := "none"
        if kind, present := provider.credential_kind.?; present {
            credential = kind == .Api_Key ? "api_key" : "oauth"
        }

        state := provider.restart_required ? "restart required" : "current"
        fmt.printfln("%s\t%s\t%s", provider.provider_id, credential, state)
    }
}

provider_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    state := (^Provider_State)(c.user_data)
    state.done = true
}

provider_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    state := (^Provider_State)(c.user_data)
    if !state.failed {
        if err == .Transport_Failed {
            fmt.eprintfln("yuke provider: daemon connection failed: %v", c.transport_error)
        } else {
            fmt.eprintfln("yuke provider: daemon protocol failed: %v", err)
        }
    }
    state.failed = true
    if c.state == .Closed {
        state.done = true
    }
}

provider_on_timeout :: proc(_: ^nbio.Operation, state: ^Provider_State) {
    state.timed_out = true
    client.client_close(state.client)
}

provider_key_prompt :: proc() -> (key: string, err: Provider_Prompt_Error) {
    fmt.fprint(os.stderr, "API key: ")
    os.flush(os.stderr)

    raw, term_err := term.enable_raw_mode(term.Tty_Handle(os.fd(os.stdin)))
    if term_err != .None {
        return "", .Terminal
    }

    bytes: [wire.LIMITS.max_api_key_bytes]byte
    defer crypto.zero_explicit(raw_data(bytes[:]), len(bytes))
    defer {
        if term.disable_raw_mode(raw) != .None && err == .None {
            secret.string_destroy(&key)
            err = .Terminal
        }
        fmt.fprintln(os.stderr)
    }

    typed := 0
    one: [1]byte
    defer crypto.zero_explicit(raw_data(one[:]), len(one))
    for {
        n, read_err := os.read(os.stdin, one[:])
        if read_err != nil || n != 1 {
            return "", .Terminal
        }

        switch one[0] {
        case '\r', '\n':
            if typed == 0 {
                return "", .Empty
            }

            text := string(bytes[:typed])
            if !utf8.valid_string(text) {
                return "", .Invalid_Utf8
            }

            cloned, clone_err := strings.clone(text)
            if clone_err != nil {
                return "", .Out_Of_Memory
            }

            return cloned, .None

        case 0x03, 0x04:
            return "", .Canceled

        case 0x08, 0x7f:
            if typed > 0 {
                typed -= 1
                bytes[typed] = 0
            }

        case:
            if typed == len(bytes) {
                return "", .Too_Long
            }
            bytes[typed] = one[0]
            typed += 1
        }
    }
}

provider_prompt_error_print :: proc(err: Provider_Prompt_Error) {
    switch err {
    case .None:
        unreachable()
    case .Terminal:
        fmt.eprintln("yuke provider: API key must be entered from a terminal")
    case .Empty:
        fmt.eprintln("yuke provider: API key cannot be empty")
    case .Too_Long:
        fmt.eprintln("yuke provider: API key is too long")
    case .Invalid_Utf8:
        fmt.eprintln("yuke provider: API key is not valid UTF-8")
    case .Out_Of_Memory:
        fmt.eprintln("yuke provider: out of memory while reading the API key")
    case .Canceled:
        fmt.eprintln("yuke provider: canceled")
    }
}
