package daemon

import "core:log"
import "core:mem"
import "core:nbio"

import provider "src:provider"

// The provider inference service: one shared transport client for every session's turns. Ops are
// owned by their caller, which is what lets shutdown reach a turn whose cancel fires no completion.
Run_Service :: struct {
    client:    provider.Client,
    loop:      ^nbio.Event_Loop,
    allocator: mem.Allocator,
    ready:     bool,
    stopping:  bool,

    // Ops started and not yet completed or canceled; only teardown reads it.
    live:      int,
}

// Where a caller receives one turn's output. Event strings borrow the turn arena and are
// valid only until completion; anything retained must be cloned by the sink.
Run_Sink :: struct {
    on_event: proc(user: rawptr, event: provider.Stream_Event),
    on_done:  proc(user: rawptr, result: provider.Turn_Result),
    user:     rawptr,
}

// One in-flight turn. `turn` holds a curl transfer whose address libcurl retains, so a
// live op must never move; the caller heap-owns it until completion or cancellation.
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

// Stop accepting turns. Live ops belong to their callers, so the daemon cancels those; the
// service only refuses new ones from here on.
run_service_shutdown :: proc(s: ^Run_Service) {
    assert(s != nil, "run service shutdown needs a service")

    s.stopping = true
}

// Cancel one live turn and release it. `turn_cancel` is synchronous and fires no
// completion, so the caller owes whatever terminal the turn had promised.
run_cancel :: proc(s: ^Run_Service, op: ^Run_Op) {
    assert(s != nil && op != nil, "run cancel needs a service and an op")
    assert(s.live > 0, "cancelling a turn the service does not count")

    provider.turn_cancel(&op.turn)
    s.live -= 1
    free(op, s.allocator)
}

run_service_destroy :: proc(s: ^Run_Service) {
    assert(s != nil, "run service teardown needs a service")
    assert(s.live == 0, "run service destroyed with a live turn")

    if s.ready {
        provider.client_destroy(&s.client)
        s.ready = false
    }
}

run_service_busy :: proc(s: ^Run_Service) -> bool {
    assert(s != nil, "run service busy check needs a service")

    return s.live > 0
}

// Start one turn against `connection` with an already-built body. Nil means nothing started; an op
// means exactly one `on_done` follows, and the caller owns it until then.
run_begin :: proc(s: ^Run_Service, connection: provider.Connection, body: string, sink: Run_Sink) -> ^Run_Op {
    assert(s != nil && s.ready, "a run needs an initialized service")
    assert(!s.stopping, "a run cannot start during shutdown")
    assert(sink.on_done != nil, "a run needs a completion sink")
    assert(len(body) > 0, "a run needs a built request body")

    op, alloc_err := new(Run_Op, s.allocator)
    if alloc_err != nil {
        return nil
    }
    op^ = {
        service = s,
        sink    = sink,
    }
    s.live += 1

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
        s.live -= 1
        free(op, s.allocator)

        return nil
    }

    assert(op.turn.state == .Running, "a started run owns a running turn")

    return op
}

@(private)
run_on_event :: proc(user: rawptr, event: provider.Stream_Event) {
    op := (^Run_Op)(user)
    assert(op != nil && op.service != nil, "a run event lost its owner")

    if op.sink.on_event != nil {
        op.sink.on_event(op.sink.user, event)
    }
}

// Terminal for one turn. The op is released before the sink runs, so the sink may start
// the next turn — the queued input behind this one — from inside its own completion.
@(private)
run_on_done :: proc(user: rawptr, result: provider.Turn_Result) {
    op := (^Run_Op)(user)
    assert(op != nil && op.service != nil, "a run completion lost its owner")
    assert(op.turn.state == .Done, "a run completion needs a terminal turn")

    service := op.service
    sink := op.sink

    assert(service.live > 0, "a turn completed that the service does not count")
    service.live -= 1
    free(op, service.allocator)

    sink.on_done(sink.user, result)
}
