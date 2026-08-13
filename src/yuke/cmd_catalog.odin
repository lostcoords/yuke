package main

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:time"

import client "src:client"
import daemon "src:daemon"
import wire "src:wire"

// A refresh fetches models.dev over the network on the daemon, so allow more time than
// the daemon's own transfer budget.
CATALOG_REQUEST_TIMEOUT :: 90 * time.Second

Catalog_Action :: enum {
    Refresh,
    List,
}

Catalog_State :: struct {
    action:    Catalog_Action,
    client:    ^client.Client,
    failed:    bool,
    timed_out: bool,
    done:      bool,
}

catalog_run :: proc() -> int {
    args := os.args[2:]
    action: Catalog_Action
    switch {
    case len(args) == 1 && args[0] == "refresh":
        action = .Refresh

    case len(args) == 1 && args[0] == "list":
        action = .List

    case:
        fmt.eprintln("usage: yuke catalog refresh | list")
        return 2
    }

    if err := nbio.acquire_thread_event_loop(); err != nil {
        fmt.eprintfln("yuke catalog: event loop unavailable: %v", err)
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
        fmt.eprintfln("yuke catalog: could not prepare the daemon connection: %v", transport_err)
        return 1
    }

    state := Catalog_State {
        action = action,
    }
    c: client.Client
    state.client = &c
    open_err := client.client_open(
        &c,
        transport,
        "yuke-catalog",
        DAEMON_VERSION,
        {on_ready = catalog_on_ready, on_close = catalog_on_close, on_error = catalog_on_error},
        &state,
    )
    if open_err != .None {
        fmt.eprintfln("yuke catalog: could not connect to the daemon: %v", open_err)
        return 1
    }

    timeout := nbio.timeout_poly(CATALOG_REQUEST_TIMEOUT, &state, catalog_on_timeout, loop)
    nbio.run_until(&state.done)
    if !state.timed_out {
        nbio.remove(timeout)
    }

    client.client_destroy(&c)
    if state.timed_out {
        fmt.eprintln("yuke catalog: the daemon did not answer in time")
        return 1
    }
    if state.failed {
        return 1
    }

    return 0
}

catalog_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    state := (^Catalog_State)(c.user_data)

    send_err: client.Protocol_Error
    switch state.action {
    case .Refresh:
        _, send_err = client.client_send_request(c, .Catalog_Refresh, wire.Empty{}, catalog_on_response)

    case .List:
        _, send_err = client.client_send_request(c, .Catalog_List, wire.Catalog_List_Params{}, catalog_on_response)
    }

    if send_err != .None {
        fmt.eprintfln("yuke catalog: request could not be sent: %v", send_err)
        state.failed = true
        client.client_close(c)
    }
}

catalog_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    state := (^Catalog_State)(c.user_data)
    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        state.failed = true
        return
    }

    switch response in answered.response {
    case wire.Response_Error:
        fmt.eprintfln("yuke catalog: daemon rejected the request: %s", response.error.message)
        state.failed = true

    case wire.Response_Ok:
        switch state.action {
        case .Refresh:
            catalog_refresh_print(response.result.(wire.Catalog_Refresh_Result))

        case .List:
            catalog_list_print(response.result.(wire.Catalog_List_Result))
        }
    }

    client.client_close(c)
}

catalog_list_print :: proc(result: wire.Catalog_List_Result) {
    full, is_full := result.(wire.Catalog_List_Result_Full)
    if !is_full {
        fmt.println("catalog unchanged")
        return
    }

    revision := ([64]u8)(full.catalog_rev)
    fmt.printfln("%d model(s); revision %s", len(full.models), string(revision[:]))
    for model in full.models {
        levels := strings.join(model.reasoning_levels, ",", context.temp_allocator)
        fmt.printfln(
            "  %s\tctx=%d\tout=%d\tlevels=[%s]",
            model.id,
            model.context_window,
            model.max_output_tokens,
            levels,
        )
    }

    if message, present := full.health.load_error.?; present {
        fmt.printfln("  load error: %s", message)
    }
    for skipped in full.health.skipped {
        fmt.printfln("  skipped %s", skipped.provider)
    }
}

catalog_refresh_print :: proc(result: wire.Catalog_Refresh_Result) {
    revision := ([64]u8)(result.catalog_rev)
    fmt.printfln("catalog refreshed; revision %s", string(revision[:]))

    if message, present := result.health.load_error.?; present {
        fmt.printfln("  load error: %s", message)
    }
    for skipped in result.health.skipped {
        reason := "invalid config"
        #partial switch _ in skipped.reason {
        case wire.Skip_Reason_Missing_Credential:
            reason = "missing credential"
        }
        fmt.printfln("  skipped %s: %s", skipped.provider, reason)
    }
}

catalog_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    state := (^Catalog_State)(c.user_data)
    state.done = true
}

catalog_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    state := (^Catalog_State)(c.user_data)
    if !state.failed {
        if err == .Transport_Failed {
            fmt.eprintfln("yuke catalog: daemon connection failed: %v", c.transport_error)
        } else {
            fmt.eprintfln("yuke catalog: daemon protocol failed: %v", err)
        }
    }
    state.failed = true
    if c.state == .Closed {
        state.done = true
    }
}

catalog_on_timeout :: proc(_: ^nbio.Operation, state: ^Catalog_State) {
    state.timed_out = true
    client.client_close(state.client)
}
