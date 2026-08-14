package daemon

import "core:mem"

import wire "src:wire"

// What a session is doing now. A run never outlives its daemon, so the engine state is the
// whole truth and every activity surface reads it here rather than the log.
session_activity :: proc(d: ^Daemon, session: wire.Session_Id) -> wire.Session_Activity {
    assert(d != nil, "reading session activity needs daemon state")

    activity := wire.Session_Activity {
        state = wire.Activity_State_Idle{},
    }

    live := session_live(d, session)
    if live == nil {
        return activity
    }

    assert(len(live.queue) <= wire.LIMITS.max_queued_inputs, "the queue holds no more than its bound")
    activity.queued = u64(len(live.queue))

    run := live.run
    if run == nil {
        return activity
    }

    activity.config = run.config
    activity.state = wire.Activity_State_Running {
        run_id        = run.run_id,
        started_at_ms = run.started_at_ms,
    }

    // A running tool outranks the stream: the turn is waiting on it, not on the provider.
    // The first one still running names the phase when several run at once.
    for &block, index in run.blocks {
        if block.kind != .Tool {
            continue
        }

        running, is_running := block.tool_state.(wire.Tool_State_Running)
        if !is_running {
            continue
        }

        activity.state = wire.Activity_State_Running_Tool {
            run_id        = run.run_id,
            message_id    = run.message_id,
            part_id       = wire.Part_Id(index),
            tool_name     = block.name,
            started_at_ms = running.started_at_ms,
        }

        assert(wire.session_activity_validate(activity) == .None, "the engine built an invalid activity")

        return activity
    }

    // Only a reasoning block names a phase of its own, and only while it is the one
    // receiving deltas. A permission phase arrives with permissions.
    if len(run.blocks) > 0 {
        index := len(run.blocks) - 1
        block := &run.blocks[index]

        if block.kind == .Reasoning && !block.closed {
            activity.state = wire.Activity_State_Reasoning {
                run_id     = run.run_id,
                message_id = run.message_id,
                part_id    = wire.Part_Id(index),
            }
        }
    }

    assert(wire.session_activity_validate(activity) == .None, "the engine built an invalid activity")

    return activity
}

// The open draft and the inputs behind it, for a resync cut: `message.started` and
// `input.queued` are live-only, so a mid-turn subscriber has no other source. Borrowed.
session_draft :: proc(
    d: ^Daemon,
    session: wire.Session_Id,
    allocator: mem.Allocator,
) -> (
    draft: Maybe(wire.Active_Draft),
    queued: []wire.Queued_Input,
) {
    assert(d != nil, "reading a session draft needs daemon state")
    assert(allocator.procedure != nil, "building a draft needs an allocator")

    live := session_live(d, session)
    if live == nil {
        return nil, nil
    }

    queued = live.queue[:]

    run := live.run
    if run == nil {
        return nil, queued
    }

    // Each part carries what its block has accumulated, which is the offset the next
    // `message.part_delta` names, so folding that delta onto this cut leaves no gap.
    content, alloc_err := make([]wire.Assistant_Part, len(run.blocks), allocator)
    if alloc_err != nil {
        return nil, queued
    }

    for &block, index in run.blocks {
        content[index] = run_part_build(&block, index)
    }

    open := wire.Active_Draft {
        message = wire.Assistant_Message {
            id = run.message_id,
            run_id = run.run_id,
            config_rev = run.config.config_rev,
            agent = RUN_AGENT,
            content = content,
            time = wire.Message_Time{created_at_ms = run.started_at_ms},
        },
    }

    assert(wire.active_draft_validate(open) == .None, "the engine built an invalid draft")

    return open, queued
}

// Publish the session's activity. Called from the engine transitions rather than the
// handlers, so nothing can move the queue or the phase without announcing it.
session_activity_announce :: proc(d: ^Daemon, session: wire.Session_Id) {
    activity := session_activity(d, session)
    _ = broadcast(d, wire.Session_Activity_Changed_Data{session_id = session, activity = activity})
}
