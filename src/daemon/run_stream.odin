package daemon

import "core:log"
import "core:strings"

import qjs "libs:bindings/quickjs"

import provider "src:provider"
import wire "src:wire"

// One open assistant block and the part it folds into. Text arrives as deltas — a closed
// block carries only its terminal metadata — so the run accumulates it here.
@(private)
Run_Block :: struct {
    block_id:      provider.Stream_Block_Id,
    kind:          provider.Stream_Block_Kind,

    // The block's accumulated content: assistant text, reasoning, or a tool call's argument
    // JSON. A tool block fills this once at its terminal rather than from deltas.
    text:          strings.Builder,
    signature:     string,

    // Tool blocks only. The provider names the tool in the terminal, never at the start.
    call_id:       string,
    name:          string,

    // Nil until the call starts, which `run_part_build` reads as pending.
    tool_state:    wire.Tool_State,
    tool_started:  u64,

    // A handler's promise, owned while `tool_awaiting`. Polled rather than continued into,
    // so cancelling a run never leaves JS holding a pointer to it.
    tool_promise:  qjs.Value,
    tool_awaiting: bool,

    // Set by this block's terminal. A closed reasoning block is no longer the live phase.
    closed:        bool,
}

// What `Tool_Part.name` admits. A provider that exceeds it is not trusted to have named a
// tool we offered, but the part still has to be valid: `pump` asserts that.
@(private = "file")
TOOL_NAME_WIRE_MAX :: 128

// Fold one provider event into the draft and mirror it live. Runs on the loop thread; the
// event's strings borrow the turn arena and are copied into the run's own.
@(private)
run_on_stream :: proc(user: rawptr, event: provider.Stream_Event) {
    run := (^Run)(user)
    assert(run != nil, "a stream event lost its run")
    assert(run.daemon != nil, "a run lost its daemon")

    if run.fault != .None {
        return
    }

    switch v in event {
    case provider.Stream_Block_Started:
        run_block_open(run, v)

    case provider.Stream_Text_Delta:
        run_block_fold(run, v.block_id, v.text)

    case provider.Stream_Reasoning_Delta:
        run_block_fold(run, v.block_id, v.text)

    case provider.Stream_Block_Stopped:
        run_block_close(run, v)

    case provider.Stream_Done:
        run.finish = RUN_STOP_REASON[v.reason]
        run.finish_seen = true
        run.usage = wire.Token_Usage {
            input       = v.usage.input,
            output      = v.usage.output,
            reasoning   = v.usage.reasoning,
            cache_read  = v.usage.cache_read,
            cache_write = v.usage.cache_write,
        }
    }
}

// Open one block as the next part ordinal.
@(private)
run_block_open :: proc(run: ^Run, started: provider.Stream_Block_Started) {
    if len(run.blocks) >= wire.LIMITS.max_message_parts {
        run.fault = .Transcript_Limit

        return
    }

    if _, err := append(
        &run.blocks,
        Run_Block{block_id = started.block_id, kind = started.kind, text = strings.builder_make(run.round_allocator)},
    ); err != nil {
        run.fault = .Resource

        return
    }

    index := len(run.blocks) - 1

    // A tool block announces at its terminal instead: the provider names the tool there, so
    // until then there is no part a client could render.
    if started.kind == .Tool {
        return
    }

    added := wire.Message_Part_Added_Data {
        session_id = run.session,
        message_id = run.message_id,
        part       = run_part_build(&run.blocks[index], index),
    }
    _ = broadcast(run.daemon, added)

    // A block boundary is the only point inside a turn where the phase moves; deltas never
    // change it and never announce.
    session_activity_announce(run.daemon, run.session)
}

// Append `text` to its block and mirror the same bytes as a delta. `offset` is what the
// receiver already holds, so a dropped delta shows as a gap rather than corruption.
@(private = "file")
run_block_fold :: proc(run: ^Run, block_id: provider.Stream_Block_Id, text: string) {
    block, index := run_block_find(run, block_id)
    if block == nil {
        return
    }

    if !run_string_add(run, len(text)) {
        return
    }

    offset := u64(len(strings.to_string(block.text)))
    if strings.write_string(&block.text, text) != len(text) {
        run.fault = .Resource

        return
    }

    delta := wire.Part_Delta {
        session_id = run.session,
        message_id = run.message_id,
        part_id    = wire.Part_Id(index),
        delta      = text,
        offset     = offset,
    }
    _ = broadcast(run.daemon, wire.Message_Part_Delta_Data(delta))
}

// Close one block, keeping the terminal metadata only the reasoning arms carry.
@(private = "file")
run_block_close :: proc(run: ^Run, stopped: provider.Stream_Block_Stopped) {
    block, index := run_block_find(run, stopped.block_id)
    if block == nil {
        return
    }

    was_open := !block.closed
    block.closed = true

    // Only the newest reasoning block names a phase, so closing anything else is invisible.
    if was_open && block.kind == .Reasoning && block == &run.blocks[len(run.blocks) - 1] {
        session_activity_announce(run.daemon, run.session)
    }

    #partial switch result in stopped.result {
    case provider.Stream_Reasoning_Block:
        run_block_signature_set(run, block, result.signature)

    case provider.Stream_Redacted_Reasoning_Block:
        run_block_signature_set(run, block, result.data)

    case provider.Stream_Tool_Block:
        run_tool_adopt(run, block, index, result.call)
    }
}

// Adopt the completed call and announce its part. Nothing executes it yet: the part enters
// the transcript pending, which is what a client renders while a decision is outstanding.
@(private = "file")
run_tool_adopt :: proc(run: ^Run, block: ^Run_Block, index: int, call: provider.Tool_Call) {
    name := call.name

    if len(name) > TOOL_NAME_WIRE_MAX {
        log.warnf("daemon: session %v truncated a %d byte tool name", run.session, len(name))
        name = name[:utf8_floor(name, TOOL_NAME_WIRE_MAX)]
    }

    if !run_string_add(run, len(name) + len(call.id) + len(call.arguments)) {
        run_block_drop_unannounced(run, index)

        return
    }

    owned_name, name_err := strings.clone(name, run.round_allocator)
    owned_id, id_err := strings.clone(call.id, run.round_allocator)
    if name_err != nil || id_err != nil {
        run.fault = .Resource
        run_block_drop_unannounced(run, index)

        return
    }
    if strings.write_string(&block.text, call.arguments) != len(call.arguments) {
        run.fault = .Resource
        run_block_drop_unannounced(run, index)

        return
    }
    block.name = owned_name
    block.call_id = owned_id

    added := wire.Message_Part_Added_Data {
        session_id = run.session,
        message_id = run.message_id,
        part       = run_part_build(block, index),
    }
    _ = broadcast(run.daemon, added)
}

// Drop a tool block whose part was never announced: keeping an incomplete part would make a
// concurrent draft resync invalid. Neutral streams serialize blocks, so it is normally the tail.
@(private = "file")
run_block_drop_unannounced :: proc(run: ^Run, index: int) {
    assert(run != nil, "dropping an unannounced block needs its run")
    assert(index >= 0 && index < len(run.blocks), "an unannounced block has a part ordinal")

    if index == len(run.blocks) - 1 {
        ordered_remove(&run.blocks, index)
    }
}

@(private = "file")
run_block_signature_set :: proc(run: ^Run, block: ^Run_Block, signature: string) {
    if !run_string_add(run, len(signature)) {
        return
    }

    owned, err := strings.clone(signature, run.round_allocator)
    if err != nil {
        run.fault = .Resource

        return
    }
    block.signature = owned
}

// Reserve payload bytes before retaining provider or tool output. A fault latches for the
// round; later stream events are ignored and the valid draft prefix is discarded.
@(private)
run_string_add :: proc(run: ^Run, bytes: int) -> bool {
    assert(run != nil, "reserving draft bytes needs a run")
    assert(run.string_bytes >= len(RUN_AGENT), "draft bytes include its agent")
    assert(bytes >= 0, "draft byte growth is non-negative")

    if run.fault != .None {
        return false
    }

    if bytes > wire.LIMITS.max_message_string_bytes - run.string_bytes {
        run.fault = .Transcript_Limit

        return false
    }

    run.string_bytes += bytes

    return true
}

// The largest length at or below `limit` that does not split a UTF-8 sequence.
@(private = "file")
utf8_floor :: proc(text: string, limit: int) -> int {
    end := min(limit, len(text))

    for end > 0 && end < len(text) && text[end] & 0xC0 == 0x80 {
        end -= 1
    }

    return end
}

// The open block `block_id` names and its part ordinal, or nil. Blocks are few and ordered, so a
// scan is the lookup; a provider naming an unopened block is peer data, not an invariant.
@(private = "file")
run_block_find :: proc(run: ^Run, block_id: provider.Stream_Block_Id) -> (^Run_Block, int) {
    for &block, index in run.blocks {
        if block.block_id == block_id {
            return &block, index
        }
    }

    return nil, 0
}

// The wire part one block currently represents, borrowing the block's own buffer.
@(private)
run_part_build :: proc(block: ^Run_Block, index: int) -> wire.Assistant_Part {
    text := strings.to_string(block.text)
    id := wire.Part_Id(index)

    switch block.kind {
    case .Text:
        return wire.Text_Part{id = id, text = text}

    case .Reasoning:
        return wire.Reasoning_Part{id = id, text = text, signature = block.signature}

    case .Redacted_Reasoning:
        return wire.Redacted_Reasoning_Part{id = id, data = block.signature}

    case .Tool:
        call_id: Maybe(string)

        if block.call_id != "" {
            call_id = block.call_id
        }

        state := block.tool_state
        if state == nil {
            state = wire.Tool_State_Pending{}
        }

        return wire.Tool_Part{id = id, call_id = call_id, name = block.name, arguments = text, state = state}
    }

    unreachable()
}

// Provider and wire stop reasons are separate closed sets. Indexed by the enum, so a new provider
// reason fails the build rather than defaulting silently.
@(private = "file", rodata)
RUN_STOP_REASON := [provider.Stop_Reason]wire.Stop_Reason {
    .End_Turn       = .Stop,
    .Stop_Sequence  = .Stop,
    .Tool_Calls     = .Tool_Calls,
    .Max_Tokens     = .Length,
    .Content_Filter = .Content_Filter,
    .Unknown        = .Unknown,
}
