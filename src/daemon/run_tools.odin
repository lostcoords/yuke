package daemon

import "core:strings"

import qjs "libs:bindings/quickjs"
import js "src:js"
import wire "src:wire"

// One round's tool calls. Every handler starts together and the turn commits when the last
// settles, because a transcript carrying a pending tool part is refused by every request
// builder: committing one would make the session unusable from that message on.
//
// Handlers are polled through their promises rather than continued into. Nothing in JS ends
// up holding a pointer to the run, so cancelling a turn frees it without a dangling callback.

// Start every call the draft is still waiting on. True when one is outstanding, in which case
// the join commits the turn instead of the caller.
run_tools_begin :: proc(run: ^Run) -> bool {
    assert(run != nil, "starting tools needs a run")
    assert(run.daemon != nil, "starting tools needs daemon state")
    assert(run.op == nil, "tools start after the provider turn releases its op")
    assert(run_tools_open(run) == 0, "a round starts with no tool outstanding")
    assert(!run.tools_joining, "a round starts before its tool join")

    d := run.daemon
    now := now_ms()

    for &block, index in run.blocks {
        if run.fault != .None {
            break
        }

        if block.kind != .Tool || block.tool_state != nil {
            continue
        }

        tool := tools_find(d, block.name)

        if tool == nil {
            run_tool_settle(run, &block, index, wire.Tool_State_Error{message = "unknown tool"}, 0)

            continue
        }

        block.tool_started = now
        run_tool_state_set(run, &block, index, wire.Tool_State_Running{started_at_ms = now})

        run_tool_call(run, &block, index, tool^)
    }

    // A promise can already be settled without queuing a microtask.
    run_tools_poll(run)
    if run_tools_open(run) == 0 {
        return false
    }

    // Mark the join before the drain. Its hook can settle the last promise and free `run`,
    // so nothing after the drain can read through that pointer.
    run.tools_joining = true
    js.drain(&d.js)

    return true
}

// Call one handler and retain its promise until the join observes a terminal state.
@(private = "file")
run_tool_call :: proc(run: ^Run, block: ^Run_Block, index: int, tool: Daemon_Tool) {
    ctx := run.daemon.js.ctx
    assert(ctx != nil, "calling a tool needs a live context")
    assert(block.kind == .Tool, "only a tool block calls a handler")
    assert(!block.tool_awaiting, "a tool handler starts once")
    assert(index >= 0 && index < len(run.blocks), "a tool call needs its part ordinal")
    assert(qjs.is_function(ctx, tool.handler), "a registered tool retains its handler")

    arguments := strings.to_string(block.text)

    if arguments == "" {
        arguments = "{}"
    }

    args := qjs.parse_json(ctx, arguments)

    if qjs.is_exception(args) {
        qjs.free_value(ctx, args)
        exception := qjs.get_exception(ctx)
        qjs.free_value(ctx, exception)
        run_tool_raise(run, block, index, "arguments were not valid JSON")

        return
    }

    argv := [2]qjs.Value{args, run.cancel_signal}
    js.cancel_enforce(&run.daemon.js)
    result := js.call_value(&run.daemon.js, tool.handler, qjs.undefined(), argv[:])
    qjs.free_value(ctx, args)

    if qjs.is_exception(result) {
        qjs.free_value(ctx, result)
        run_tool_raise(run, block, index, run_tool_exception(run))

        return
    }

    if qjs.promise_state(ctx, result) == .Not_A_Promise {
        output, ok := run_tool_output(run, result)

        if ok {
            run_tool_settle(run, block, index, wire.Tool_State_Completed{output = output})
        } else {
            run_tool_raise(run, block, index, "tool output was not JSON-serializable")
        }

        qjs.free_value(ctx, result)

        return
    }

    block.tool_promise = result
    block.tool_awaiting = true
}

// Settle whatever finished since the last drain.
run_tools_poll :: proc(run: ^Run) {
    assert(run != nil, "polling tools needs a run")
    assert(run.daemon != nil, "polling tools needs daemon state")
    ctx := run.daemon.js.ctx
    assert(ctx != nil, "polling tools needs a live context")

    for &block, index in run.blocks {
        if !block.tool_awaiting {
            continue
        }

        state := qjs.promise_state(ctx, block.tool_promise)

        if state == .Pending {
            continue
        }

        assert(state == .Fulfilled || state == .Rejected, "an owned tool promise has a promise state")

        value := qjs.promise_result(ctx, block.tool_promise)

        if state == .Fulfilled {
            output, ok := run_tool_output(run, value)

            if ok {
                run_tool_settle(run, &block, index, wire.Tool_State_Completed{output = output})
            } else {
                run_tool_raise(run, &block, index, "tool output was not JSON-serializable")
            }
        } else {
            run_tool_settle(run, &block, index, wire.Tool_State_Error{message = run_tool_message(run, value)})
        }

        qjs.free_value(ctx, value)
        qjs.free_value(ctx, block.tool_promise)
        block.tool_promise = {}
        block.tool_awaiting = false
    }
}

// Release any promise a canceled or failed run still owns.
run_tools_release :: proc(run: ^Run) {
    assert(run != nil, "releasing tools needs a run")
    assert(run.daemon != nil, "releasing tools needs daemon state")
    ctx := run.daemon.js.ctx
    assert(ctx != nil, "releasing tools needs a live context")

    for &block in run.blocks {
        if !block.tool_awaiting {
            continue
        }

        qjs.free_value(ctx, block.tool_promise)
        block.tool_promise = {}
        block.tool_awaiting = false
    }

    run.tools_joining = false
}

run_tools_open :: proc(run: ^Run) -> int {
    assert(run != nil, "counting open tools needs a run")

    count := 0
    for &block in run.blocks {
        if block.tool_awaiting {
            count += 1
        }
    }

    return count
}

// Record a terminal state and announce it. The duration is filled here so every terminal
// reports one, whichever path produced it.
@(private = "file")
run_tool_settle :: proc(
    run: ^Run,
    block: ^Run_Block,
    index: int,
    state: wire.Tool_State,
    duration_ms: Maybe(u64) = nil,
) {
    if run.fault != .None {
        return
    }

    bytes := 0
    switch value in state {
    case wire.Tool_State_Completed:
        bytes = len(value.output)

    case wire.Tool_State_Error:
        bytes = len(value.message)

    case wire.Tool_State_Pending,
         wire.Tool_State_Waiting_Permission,
         wire.Tool_State_Running,
         wire.Tool_State_Denied,
         wire.Tool_State_Canceled:
        assert(false, "settling a tool needs a terminal execution state")
    }

    if !run_string_add(run, bytes) {
        return
    }

    elapsed: u64

    if duration, supplied := duration_ms.?; supplied {
        elapsed = duration
    } else {
        assert(block.tool_started > 0, "a settled tool has a start time")
        elapsed = now_ms() - block.tool_started
    }

    final := state

    switch &value in final {
    case wire.Tool_State_Completed:
        value.duration_ms = elapsed

    case wire.Tool_State_Error:
        value.duration_ms = elapsed

    case wire.Tool_State_Pending,
         wire.Tool_State_Waiting_Permission,
         wire.Tool_State_Running,
         wire.Tool_State_Denied,
         wire.Tool_State_Canceled:
        assert(false, "settling a tool needs a terminal execution state")
    }

    run_tool_state_set(run, block, index, final)
}

@(private = "file")
run_tool_state_set :: proc(run: ^Run, block: ^Run_Block, index: int, state: wire.Tool_State) {
    assert(run != nil && run.daemon != nil, "changing a tool needs its run")
    assert(block != nil && block.kind == .Tool, "only a tool block has tool state")
    assert(index >= 0 && index < len(run.blocks), "a tool state needs its part ordinal")

    block.tool_state = state

    changed := wire.Tool_State_Changed_Data {
        session_id = run.session,
        message_id = run.message_id,
        part_id    = wire.Part_Id(index),
        state      = state,
    }
    _ = broadcast(run.daemon, changed)

    session_activity_announce(run.daemon, run.session)
}

@(private = "file")
run_tool_raise :: proc(run: ^Run, block: ^Run_Block, index: int, message: string) {
    run_tool_settle(run, block, index, wire.Tool_State_Error{message = message})
}

// The pending exception as model-facing text. Clears it, so a later entry does not inherit it.
@(private = "file")
run_tool_exception :: proc(run: ^Run) -> string {
    assert(run != nil && run.daemon != nil, "reading a tool exception needs its run")

    ctx := run.daemon.js.ctx
    assert(ctx != nil, "reading a tool exception needs a live context")

    thrown := qjs.get_exception(ctx)

    defer qjs.free_value(ctx, thrown)

    return run_tool_message(run, thrown)
}

// A handler's value as the text the model reads. A string is its own output; anything else is
// JSON, so an object result reaches the model as data rather than "[object Object]". False
// means conversion threw or the value has no JSON representation.
@(private = "file")
run_tool_output :: proc(run: ^Run, value: qjs.Value) -> (string, bool) {
    assert(run != nil && run.daemon != nil, "reading tool output needs its run")

    ctx := run.daemon.js.ctx
    assert(ctx != nil, "reading tool output needs a live context")

    if qjs.is_undefined(value) || qjs.is_null(value) {
        return "", true
    }

    if qjs.is_string(value) {
        return run_tool_clone(run, value), true
    }

    encoded := qjs.json_stringify(ctx, value)

    if qjs.is_exception(encoded) {
        qjs.free_value(ctx, encoded)
        exception := qjs.get_exception(ctx)
        qjs.free_value(ctx, exception)

        return "", false
    }

    if qjs.is_undefined(encoded) {
        qjs.free_value(ctx, encoded)

        return "", false
    }

    defer qjs.free_value(ctx, encoded)

    return run_tool_clone(run, encoded), true
}

// A failure as the text the model reads. `String(e)` rather than JSON: an Error serializes to
// an empty object, and its message is the whole point.
@(private = "file")
run_tool_message :: proc(run: ^Run, value: qjs.Value) -> string {
    assert(run != nil, "reading a tool failure needs its run")

    return run_tool_clone(run, value)
}

@(private = "file")
run_tool_clone :: proc(run: ^Run, value: qjs.Value) -> string {
    assert(run != nil && run.daemon != nil, "cloning a tool value needs its run")

    ctx := run.daemon.js.ctx
    assert(ctx != nil, "cloning a tool value needs a live context")

    text, readable := qjs.to_string(ctx, value)

    if !readable {
        exception := qjs.get_exception(ctx)
        qjs.free_value(ctx, exception)

        return ""
    }

    defer qjs.free_string(ctx, text)

    cloned, err := strings.clone(text, run.round_allocator)
    if err != nil {
        run.fault = .Resource

        return ""
    }

    return cloned
}

// Loop thread, after every drain: settle what finished and commit a round that is done. The
// map is re-scanned per join because committing a turn can remove the session from it.
js_on_drain :: proc(user: rawptr) {
    d := (^Daemon)(user)
    assert(d != nil, "the daemon drain hook needs daemon state")

    for _, live in d.sessions {
        run := live.run
        if run != nil && run_tools_open(run) > 0 {
            run_tools_poll(run)
        }
    }

    for {
        joined: ^Run

        for _, live in d.sessions {
            run := live.run
            if run != nil && run.tools_joining && run_tools_open(run) == 0 {
                joined = run

                break
            }
        }

        if joined == nil {
            return
        }

        joined.tools_joining = false
        if joined.fault != .None {
            run_fail_fault(joined)
        } else {
            run_commit(joined)
        }
    }
}
