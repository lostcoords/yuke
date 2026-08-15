package daemon

import "core:log"
import "core:mem"
import "core:mem/virtual"

import store "src:daemon/store"
import wire "src:wire"

@(private = "file")
Queued_Input_Owned :: struct {
    arena: mem.Dynamic_Arena,
    input: wire.Queued_Input,
}

// A session's live engine state: the turn in flight and the inputs waiting behind it.
// One turn at a time per session, because two turns writing one transcript would
// interleave its sequence; different sessions run concurrently on the shared transport.
Session_Live :: struct {
    run:   ^Run,

    // Accepted inputs not yet promoted to a user message, oldest first. Their content is
    // cloned out of the frame arena, which does not survive the request that queued them.
    queue: [dynamic]Queued_Input_Owned,
}

// The session's live state, or nil when it has neither a turn nor a queue.
session_live :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Session_Live {
    assert(d != nil, "session state needs daemon state")

    return d.sessions[session] or_else nil
}

// The session's live turn, or nil.
session_live_run :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Run {
    live := session_live(d, session)
    if live == nil {
        return nil
    }

    return live.run
}

// The session's live state, created empty if it has none. Nil only under allocation
// failure, which the caller reports rather than announcing a turn it cannot track.
@(private)
session_live_ensure :: proc(d: ^Daemon, session: wire.Session_Id) -> ^Session_Live {
    if existing := session_live(d, session); existing != nil {
        return existing
    }

    live, alloc_err := new(Session_Live, d.allocator)
    if alloc_err != nil {
        return nil
    }

    live.queue = make([dynamic]Queued_Input_Owned, d.allocator)

    if map_insert(&d.sessions, session, live) == nil {
        session_live_free(d, live)

        return nil
    }

    return live
}

// Release one session's state and every independently owned queued input.
@(private)
session_live_free :: proc(d: ^Daemon, live: ^Session_Live) {
    assert(live != nil, "freeing session state needs state")
    assert(live.run == nil, "session state freed with a live turn")

    for &queued in live.queue {
        queued_input_owned_destroy(&queued)
    }
    delete(live.queue)
    free(live, d.allocator)
}

// Drop the session's state once it holds neither a turn nor a queue, so an idle daemon
// tracks nothing.
@(private)
session_live_release :: proc(d: ^Daemon, session: wire.Session_Id) {
    live := session_live(d, session)
    if live == nil || live.run != nil || len(live.queue) > 0 {
        return
    }

    delete_key(&d.sessions, session)
    session_live_free(d, live)
}

// Accept an input behind the session's live turn. The content is cloned into the session's
// own arena: it was decoded into the frame arena, which is reset when the request returns.
session_queue_push :: proc(d: ^Daemon, session: wire.Session_Id, queued: wire.Queued_Input) -> bool {
    live := session_live(d, session)
    assert(live != nil && live.run != nil, "an input queues only behind a live turn")
    assert(len(live.queue) < wire.LIMITS.max_queued_inputs, "the queue accepted an input past its bound")

    owned := queued_input_owned_clone(queued, d.allocator)

    if _, err := append(&live.queue, owned); err != nil {
        queued_input_owned_destroy(&owned)

        return false
    }

    session_activity_announce(d, session)

    return true
}

// How many inputs are waiting behind the session's turn.
session_queue_depth :: proc(d: ^Daemon, session: wire.Session_Id) -> int {
    live := session_live(d, session)
    if live == nil {
        return 0
    }

    return len(live.queue)
}

// The highest input id this session has handed out: the store's mark covers committed
// inputs, and the queue tail covers the ones accepted but not yet promoted.
session_input_high :: proc(d: ^Daemon, session: wire.Session_Id, mark: wire.Input_Id) -> wire.Input_Id {
    live := session_live(d, session)
    if live == nil || len(live.queue) == 0 {
        return mark
    }

    tail := live.queue[len(live.queue) - 1].input.input_id
    assert(tail >= mark, "a queued input predates the store's own mark")

    return tail
}

// Remove one queued input by id, for `session.cancel_input`. Its content dies with the
// session's arena, which is reclaimed when the session goes idle.
session_queue_remove :: proc(d: ^Daemon, session: wire.Session_Id, input_id: wire.Input_Id) -> bool {
    live := session_live(d, session)
    if live == nil {
        return false
    }

    for &queued, index in live.queue {
        if queued.input.input_id == input_id {
            queued_input_owned_destroy(&queued)
            ordered_remove(&live.queue, index)
            session_activity_announce(d, session)

            return true
        }
    }

    return false
}

// Drop every queued input, for `cancel_run`'s `clear_queue`. Returns the ids dropped, in
// queue order, allocated in `sa` for the answer that reports them.
session_queue_clear :: proc(d: ^Daemon, session: wire.Session_Id, sa: mem.Allocator) -> []wire.Input_Id {
    live := session_live(d, session)
    if live == nil || len(live.queue) == 0 {
        return nil
    }

    cleared := make([]wire.Input_Id, len(live.queue), sa)
    for &queued, index in live.queue {
        cleared[index] = queued.input.input_id
        queued_input_owned_destroy(&queued)
    }

    clear(&live.queue)
    session_activity_announce(d, session)

    return cleared
}

// What promoting one queued input decided.
@(private = "file")
Promote_Outcome :: enum {
    // A turn is live, or a terminal already drained the queue: this drain is finished.
    Settled,

    // The input committed but its turn was refused. The message stands; drain on.
    Refused,

    // Nothing committed. The caller retracts the input and drains on.
    Failed,
}

// Drain the queue, one input at a time. A loop rather than a recursion so a run of failing
// inputs releases each one's arena before taking the next, and nothing is stranded behind a
// session with no turn.
@(private)
session_promote_next :: proc(d: ^Daemon, session: wire.Session_Id) {
    for {
        live := session_live(d, session)
        assert(live == nil || live.run == nil, "a session promotes an input only between turns")

        // Settled: the engine holds nothing more, and this is the one place that says so.
        if live == nil || len(live.queue) == 0 {
            session_live_release(d, session)
            session_activity_announce(d, session)

            return
        }

        next := live.queue[0]
        ordered_remove(&live.queue, 0)
        input_id := next.input.input_id
        outcome := session_promote_one(d, session, next.input)
        queued_input_owned_destroy(&next)

        switch outcome {
        case .Settled:
            return

        case .Failed:
            session_input_drop(d, session, input_id)

        case .Refused:
        }
    }
}

// Commit one promoted input as a user message and start its turn. Its storage is released
// before returning, so a failing drain holds one input's memory at a time.
@(private = "file")
session_promote_one :: proc(d: ^Daemon, session: wire.Session_Id, input: wire.Queued_Input) -> Promote_Outcome {
    scratch: virtual.Arena
    if virtual.arena_init_growing(&scratch) != nil {
        log.errorf("daemon: session %v could not promote its queued input", session)

        return .Failed
    }

    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    snapshot, found, serr := store.session_snapshot(d.store, session, sa)
    if serr != nil || !found {
        log.errorf("daemon: session %v could not read the session behind its queue: %v", session, serr)

        return .Failed
    }

    hw, hw_err := store.high_water(d.store, session)
    if hw_err != nil {
        log.errorf("daemon: session %v could not read its marks to promote an input: %v", session, hw_err)

        return .Failed
    }

    // The queued input's user message commits now, not when it was accepted: the client
    // dequeues it on this commit, so committing earlier would empty the queue while the
    // input still waited.
    committed := wire.User_Message {
        id = hw.message_id + 1,
        content = input.content,
        input_id = input.input_id,
        time = wire.Created_Time{created_at_ms = now_ms()},
    }

    if perr := broadcast(d, wire.Message_Committed_Data{session_id = session, message = committed}); perr != .None {
        log.errorf("daemon: session %v could not commit its queued input: %v", session, perr)

        return .Failed
    }

    session_summary_announce(d, session, sa)

    // A refused turn keeps its committed message and drains on. `Terminated` already
    // drained, and draining again would promote behind a live turn.
    _, start_err := run_turn_start(d, snapshot.session)

    if start_err == .None || start_err == .Terminated {
        return .Settled
    }

    log.errorf("daemon: session %v could not run its queued input: %v", session, start_err)

    return .Refused
}

@(private = "file")
queued_input_owned_clone :: proc(src: wire.Queued_Input, backing: mem.Allocator) -> Queued_Input_Owned {
    owned: Queued_Input_Owned
    mem.dynamic_arena_init(&owned.arena, backing, backing)
    owned.input = wire.queued_input_clone(src, mem.dynamic_arena_allocator(&owned.arena))

    return owned
}

@(private = "file")
queued_input_owned_destroy :: proc(owned: ^Queued_Input_Owned) {
    assert(owned != nil, "destroying a queued input needs its owner")

    mem.dynamic_arena_destroy(&owned.arena)
    owned^ = {}
}

// Retract an input promoted out of the queue but never committed, so no subscriber holds
// one that will never arrive. The caller drains on.
@(private = "file")
session_input_drop :: proc(d: ^Daemon, session: wire.Session_Id, input_id: wire.Input_Id) {
    _ = broadcast(d, wire.Input_Canceled_Data{session_id = session, input_id = input_id})
}
