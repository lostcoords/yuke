package daemon

import "core:log"
import "core:mem"
import "core:nbio"

import provider "src:provider"

// The provider inference service: one shared transport client and a single-flight run
// slot. A session may have at most one live turn, because two turns writing one
// transcript would interleave its sequence; separate sessions get separate services.
Run_Service :: struct {
    client:    provider.Client,
    loop:      ^nbio.Event_Loop,
    allocator: mem.Allocator,
    ready:     bool,
    stopping:  bool,
    live:      ^Run_Op,
}

// Where a caller receives one turn's output. Event strings borrow the turn arena and are
// valid only until completion; anything retained must be cloned by the sink.
Run_Sink :: struct {
    on_event: proc(user: rawptr, event: provider.Stream_Event),
    on_done:  proc(user: rawptr, result: provider.Turn_Result),
    user:     rawptr,
}

// One in-flight turn. `turn` holds a curl transfer whose address libcurl retains, so a
// live op must never move; it is heap-owned by the service until completion.
@(private)
Run_Op :: struct {
    turn:    provider.Turn,
    service: ^Run_Service,
    sink:    Run_Sink,
}

run_service_init :: proc(s: ^Run_Service, loop: ^nbio.Event_Loop, allocator: mem.Allocator) -> Error {
    assert(s != nil && loop != nil, "run service init needs a service and a loop")
    assert(!s.ready, "run service initialized twice")

    if err := provider.client_init(&s.client, loop, allocator); err != .None {
        log.errorf("daemon: provider transport unavailable: %v", err)
        return .Provider_Failed
    }

    s.loop = loop
    s.allocator = allocator
    s.ready = true

    return .None
}

// Stop accepting turns and cancel the live one. `turn_cancel` is synchronous and fires no
// completion, so the caller's `on_done` never runs for a canceled turn.
run_service_shutdown :: proc(s: ^Run_Service) {
    assert(s != nil, "run service shutdown needs a service")
    s.stopping = true

    if op := s.live; op != nil {
        provider.turn_cancel(&op.turn)
        s.live = nil
        free(op, s.allocator)
    }
}

run_service_destroy :: proc(s: ^Run_Service) {
    assert(s != nil, "run service teardown needs a service")
    assert(s.live == nil, "run service destroyed with a live turn")

    if s.ready {
        provider.client_destroy(&s.client)
        s.ready = false
    }
}

run_service_busy :: proc(s: ^Run_Service) -> bool {
    assert(s != nil, "run service busy check needs a service")

    return s.live != nil
}

// Start one turn against `connection` with an already-built body. Single-flight: the
// caller checks `run_service_busy` first. False means nothing started and no callback
// will fire; true means exactly one `on_done` follows.
run_begin :: proc(s: ^Run_Service, connection: provider.Connection, body: string, sink: Run_Sink) -> bool {
    assert(s != nil && s.ready, "a run needs an initialized service")
    assert(!s.stopping, "a run cannot start during shutdown")
    assert(!run_service_busy(s), "a run must be single flight")
    assert(sink.on_done != nil, "a run needs a completion sink")
    assert(len(body) > 0, "a run needs a built request body")

    op, alloc_err := new(Run_Op, s.allocator)
    if alloc_err != nil {
        return false
    }
    op^ = {
        service = s,
        sink    = sink,
    }
    s.live = op

    // `turn_start` copies the body, so the caller may release it as soon as this returns.
    err := provider.turn_start(
        &op.turn,
        &s.client,
        {connection = connection, body = body},
        {on_event = run_on_event, on_done = run_on_done},
        op,
    )
    if err != .None {
        log.errorf("daemon: provider turn did not start: %v", err)
        s.live = nil
        free(op, s.allocator)

        return false
    }

    assert(op.turn.state == .Running, "a started run owns a running turn")

    return true
}

@(private)
run_on_event :: proc(user: rawptr, event: provider.Stream_Event) {
    op := (^Run_Op)(user)
    assert(op != nil && op.service.live == op, "a run event lost its owner")

    if op.sink.on_event != nil {
        op.sink.on_event(op.sink.user, event)
    }
}

// Terminal for one turn. The slot is released before the sink runs, so the sink may
// start the next turn from inside its own completion.
@(private)
run_on_done :: proc(user: rawptr, result: provider.Turn_Result) {
    op := (^Run_Op)(user)
    assert(op != nil && op.service.live == op, "a run completion lost its owner")
    assert(op.turn.state == .Done, "a run completion needs a terminal turn")

    service := op.service
    sink := op.sink

    service.live = nil
    free(op, service.allocator)

    sink.on_done(sink.user, result)
}
