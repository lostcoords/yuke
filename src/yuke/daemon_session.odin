package main

import "core:fmt"
import "core:nbio"
import "core:time"

import "src:client"
import "src:daemon"
import "src:wire"

// A one-shot request against the local daemon: connect over the loopback WebSocket, send
// on ready, print, exit. Shared by the subcommands that need one answer and nothing else.
// `user` is the subcommand's own state; `label` prefixes its diagnostics.
Daemon_Session :: struct {
    label:     string,
    client:    ^client.Client,
    user:      rawptr,
    on_ready:  proc(s: ^Daemon_Session),
    failed:    bool,
    timed_out: bool,
    done:      bool,
}

// Run one session to completion and return the process exit code.
daemon_session_run :: proc(
    label: string,
    timeout: time.Duration,
    on_ready: proc(s: ^Daemon_Session),
    user: rawptr,
) -> int {
    assert(label != "" && on_ready != nil, "a daemon session needs a label and a ready handler")
    assert(timeout > 0, "a daemon session needs a positive timeout")

    if err := nbio.acquire_thread_event_loop(); err != nil {
        fmt.eprintfln("%s: event loop unavailable: %v", label, err)
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
        fmt.eprintfln("%s: could not prepare the daemon connection: %v", label, transport_err)
        return 1
    }

    session := Daemon_Session {
        label    = label,
        user     = user,
        on_ready = on_ready,
    }

    c: client.Client
    session.client = &c
    open_err := client.client_open(
        &c,
        transport,
        label,
        DAEMON_VERSION,
        {on_ready = daemon_session_on_ready, on_close = daemon_session_on_close, on_error = daemon_session_on_error},
        &session,
    )
    if open_err != .None {
        fmt.eprintfln("%s: could not connect to the daemon: %v", label, open_err)
        return 1
    }

    deadline := nbio.timeout_poly(timeout, &session, daemon_session_on_timeout, loop)
    nbio.run_until(&session.done)
    if !session.timed_out {
        nbio.remove(deadline)
    }

    client.client_destroy(&c)
    if session.timed_out {
        fmt.eprintfln("%s: the daemon did not answer in time", label)
        return 1
    }

    return 1 if session.failed else 0
}

// Send the session's request. A send failure ends the session with a diagnostic.
daemon_session_send :: proc(
    s: ^Daemon_Session,
    method: wire.Method_Name,
    params: wire.Request_Params,
    on_response: client.Completion_Proc,
) {
    assert(s != nil && s.client != nil, "sending needs a live session")

    if _, send_err := client.client_send_request(s.client, method, params, on_response); send_err != .None {
        fmt.eprintfln("%s: request could not be sent: %v", s.label, send_err)
        s.failed = true
        client.client_close(s.client)
    }
}

// Unwrap a completed request into its success result. A local failure or a daemon error
// is reported here and reported as `ok = false`; the caller only handles success.
daemon_session_result :: proc(
    c: ^client.Client,
    outcome: client.Request_Outcome,
) -> (
    s: ^Daemon_Session,
    result: wire.Response_Result,
    ok: bool,
) {
    s = (^Daemon_Session)(c.user_data)

    answered, has_response := outcome.(client.Request_Response)
    if !has_response {
        s.failed = true
        return s, nil, false
    }

    switch response in answered.response {
    case wire.Response_Error:
        fmt.eprintfln("%s: daemon rejected the request: %s", s.label, response.error.message)
        s.failed = true

    case wire.Response_Ok:
        return s, response.result, true
    }

    return s, nil, false
}

@(private = "file")
daemon_session_on_ready :: proc(c: ^client.Client, _: wire.Initialize_Result) {
    s := (^Daemon_Session)(c.user_data)
    s.on_ready(s)
}

@(private = "file")
daemon_session_on_close :: proc(c: ^client.Client, _: client.Close_Code) {
    s := (^Daemon_Session)(c.user_data)
    s.done = true
}

@(private = "file")
daemon_session_on_error :: proc(c: ^client.Client, err: client.Protocol_Error) {
    s := (^Daemon_Session)(c.user_data)

    if !s.failed {
        if err == .Transport_Failed {
            fmt.eprintfln("%s: daemon connection failed: %v", s.label, c.transport_error)
        } else {
            fmt.eprintfln("%s: daemon protocol failed: %v", s.label, err)
        }
    }
    s.failed = true

    if c.state == .Closed {
        s.done = true
    }
}

@(private = "file")
daemon_session_on_timeout :: proc(_: ^nbio.Operation, s: ^Daemon_Session) {
    s.timed_out = true
    client.client_close(s.client)
}
