package main

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "src:client"
import "src:secret"
import "src:term"
import "src:wire"

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
    stage:       int,
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

    return daemon_session_run("yuke provider", PROVIDER_REQUEST_TIMEOUT, provider_on_ready, &state)
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

provider_on_ready :: proc(s: ^Daemon_Session) {
    state := (^Provider_State)(s.user)

    switch state.action {
    case .List, .Remove_Key:
        daemon_session_send(s, .Auth_List, wire.Empty{}, provider_on_response)

    case .Set_Key:
        daemon_session_send(
            s,
            .Auth_Set_Api_Key,
            wire.Auth_Set_Api_Key_Params{provider_id = wire.Provider_Id(state.provider_id), api_key = state.api_key},
            provider_on_response,
        )
        secret.string_destroy(&state.api_key)
    }
}

provider_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    s, result, ok := daemon_session_result(c, outcome)
    if ok && provider_response_apply(s, result) {
        return
    }

    client.client_close(c)
}

// Apply one success result. Returns true when a follow-up request is in flight and the
// session must stay open; false when this subcommand is finished.
provider_response_apply :: proc(s: ^Daemon_Session, result: wire.Response_Result) -> bool {
    state := (^Provider_State)(s.user)

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
                    s.failed = true
                    return false
                }
                break
            }

            state.stage = 1
            daemon_session_send(
                s,
                .Auth_Logout,
                wire.Auth_Logout_Params{provider_id = wire.Provider_Id(state.provider_id)},
                provider_on_response,
            )

            return !s.failed
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
