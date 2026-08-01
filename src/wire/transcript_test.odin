package wire

import "core:strings"
import "core:testing"

@(test)
test_tool_state_parses_pending :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"pending"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)

    state, derr := tool_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := state.(Tool_State_Pending)
    testing.expect(t, ok, "should be a pending state")
}

@(test)
test_tool_state_parses_completed :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"completed","output":"done","duration_ms":42}`, context.temp_allocator)
    defer free_all(context.temp_allocator)

    state, derr := tool_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    completed, ok := state.(Tool_State_Completed)
    testing.expect(t, ok, "should be a completed state")
    testing.expect_value(t, completed.output, "done")
    testing.expect_value(t, completed.duration_ms, u64(42))
}

@(test)
test_tool_state_canceled_requires_nullable_duration :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"type":"canceled","duration_ms":null}`)
    state, derr := tool_state_from_reader(&v)
    testing.expect(t, derr == .None, "null duration should decode")
    _, ok := state.(Tool_State_Canceled)
    testing.expect(t, ok, "should be a canceled state")

    v = decoder_init(`{"type":"canceled"}`)
    _, derr = tool_state_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "omitted duration must fail")
}

@(test)
test_tool_state_running_output_present_and_absent :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // Present in a resync snapshot: output parses and round-trips.
    {
        v := decoder_init(`{"type":"running","started_at_ms":5,"output":"compiling"}`)
        state, derr := tool_state_from_reader(&v)
        testing.expect(t, derr == .None, "decode should succeed")
        running, ok := state.(Tool_State_Running)
        testing.expect(t, ok, "should be a running state")
        out, has_out := running.output.?
        testing.expect(t, has_out, "output should be present")
        testing.expect_value(t, out, "compiling")

        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        tool_state_emit(&e, state)
        testing.expect_value(t, to_string(&e), `{"type":"running","started_at_ms":5,"output":"compiling"}`)
    }

    // Absent in a live transition: none is emitted.
    {
        e: Emitter
        emitter_init(&e)
        defer emitter_destroy(&e)
        tool_state_emit(&e, Tool_State_Running{started_at_ms = 5})
        testing.expect_value(t, to_string(&e), `{"type":"running","started_at_ms":5}`)
    }
}

@(test)
test_user_message_time_has_no_completed_at_ms :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"user","id":1,"content":[{"type":"text","text":"hi"}],"input_id":5,"time":{"created_at_ms":1700000000000}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_message_parses_user :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(
        `{"type":"user","id":1,"content":[{"type":"text","text":"hi"}],"input_id":5,"time":{"created_at_ms":1700000000000}}`,
    )

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    user, ok := msg.(User_Message)
    testing.expect(t, ok, "should be a user message")
    testing.expect_value(t, user.id, Message_Id(1))
    testing.expect_value(t, len(user.content), 1)
}

@(test)
test_message_assistant_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"assistant","id":2,"run_id":1,"config_rev":0,"agent":"main","content":[{"type":"text","id":0,"text":"hello"}],"finish":"stop","time":{"created_at_ms":1700000000000,"completed_at_ms":null}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    assistant, ok := msg.(Assistant_Message)
    testing.expect(t, ok, "should be an assistant message")
    testing.expect_value(t, assistant.id, Message_Id(2))
    testing.expect_value(t, len(assistant.content), 1)

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_message_user_reordered_fields :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // The emitter writes the discriminator first for deterministic streaming output;
    // the decoder accepts it in any member position. The body fields
    // that follow may be in any order.
    v := decoder_init(
        `{"type":"user","time":{"created_at_ms":1700000000000},"content":[{"type":"text","text":"hi"}],"id":3,"input_id":7}`,
    )

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    user, ok := msg.(User_Message)
    testing.expect(t, ok, "should be a user message")
    testing.expect_value(t, user.id, Message_Id(3))
    testing.expect_value(t, len(user.content), 1)
}

@(test)
test_message_parses_compaction :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"compaction","id":4,"run_id":1,"reason":"manual","summary":"summarized","first_kept_id":10,"tokens_before":1000,"tokens_after":500,"time":{"created_at_ms":1700000000000}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    compaction, ok := msg.(Compaction_Message)
    testing.expect(t, ok, "should be a compaction message")
    testing.expect_value(t, compaction.id, Message_Id(4))
    testing.expect_value(t, compaction.summary, "summarized")
    fk, has_fk := compaction.first_kept_id.?
    testing.expect(t, has_fk, "first_kept_id should be present")
    testing.expect_value(t, fk, Message_Id(10))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_compaction_first_kept_id_null :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"compaction","id":4,"run_id":1,"reason":"auto","summary":"s","first_kept_id":null,"tokens_before":10,"tokens_after":5,"time":{"created_at_ms":1}}`
    v := decoder_init(input)

    msg, derr := message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    compaction, ok := msg.(Compaction_Message)
    testing.expect(t, ok, "should be a compaction message")
    _, has_fk := compaction.first_kept_id.?
    testing.expect(t, !has_fk, "first_kept_id should be absent")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_assistant_part_tool_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"tool","id":0,"call_id":"c1","name":"read","arguments":"{}","state":{"type":"pending"}}`
    v := decoder_init(input)

    part, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    tool, ok := part.(Tool_Part)
    testing.expect(t, ok, "should be a tool part")
    testing.expect_value(t, tool.name, "read")
    testing.expect_value(t, u64(assistant_part_id(part)), u64(0))
    _, is_pending := tool.state.(Tool_State_Pending)
    testing.expect(t, is_pending, "state should be pending")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_assistant_part_sibling_field_rejected :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"text","id":0,"text":"hi","name":"x"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling key must be rejected")
}

@(test)
test_assistant_message_part_ordinal :: proc(t: ^testing.T) {
    // A part whose id disagrees with its content[] index is rejected.
    parts := []Assistant_Part{Text_Part{id = 3, text = "a"}}
    msg := Assistant_Message {
        id = 1,
        agent = "main",
        content = parts,
        finish = Stop_Reason.Stop,
        time = {created_at_ms = 1, completed_at_ms = 2},
    }
    testing.expect(t, assistant_message_validate(msg) == .Mismatched_Payload, "misordered part id must fail")

    // With the id matching the index it validates.
    parts[0] = Text_Part {
        id   = 0,
        text = "a",
    }
    testing.expect(t, assistant_message_validate_committed(msg) == .None, "aligned part id must pass")
}

@(test)
test_tool_part_permission_lifecycle :: proc(t: ^testing.T) {
    dec: Permission_Decision = Permission_Decision_Rule {
        rule_id        = Rule_Id(
            [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'},
        ),
        label          = "allow",
        resolved_at_ms = 2,
    }
    decided := Permission_State {
        requested_at_ms = 1,
        decision        = dec,
    }
    opts := make([]Permission_Option, 0, context.temp_allocator)
    offered := Permission_State {
        requested_at_ms = 1,
        options         = opts,
    }
    part := Tool_Part {
        id        = 0,
        name      = "read",
        arguments = "{}",
    }

    // waiting_permission with a decision already recorded is invalid.
    part.state = Tool_State_Waiting_Permission{}
    part.permission_state = decided
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "decided waiting must fail")

    // waiting_permission with no permission state at all is invalid.
    part.permission_state = nil
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "waiting without permission must fail")

    part.permission_state = offered
    testing.expect(t, tool_part_validate(part) == .None, "offered waiting must validate")

    // running with options still offered (no decision) is invalid.
    part.state = Tool_State_Running {
        started_at_ms = 2,
    }
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "undecided running must fail")

    part.permission_state = decided
    testing.expect(t, tool_part_validate(part) == .None, "decided running must validate")

    part.state = Tool_State_Completed {
        output      = "ok",
        duration_ms = 1,
    }
    part.permission_state = offered
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "undecided completed must fail")

    part.permission_state = decided
    testing.expect(t, tool_part_validate(part) == .None, "decided completed must validate")

    part.state = Tool_State_Error {
        message     = "boom",
        duration_ms = 1,
    }
    part.permission_state = offered
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "undecided error must fail")

    part.permission_state = decided
    testing.expect(t, tool_part_validate(part) == .None, "decided error must validate")

    // Daemon policy that denied without prompting leaves no permission state behind.
    part.state = Tool_State_Denied {
        reason    = "no",
        denied_by = .Policy,
    }
    part.permission_state = nil
    testing.expect(t, tool_part_validate(part) == .None, "denied without permission must validate")

    part.permission_state = offered
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "undecided denied must fail")

    part.permission_state = decided
    testing.expect(t, tool_part_validate(part) == .None, "decided denied must validate")

    // pending never carries a permission state.
    part.state = Tool_State_Pending{}
    testing.expect(t, tool_part_validate(part) == .Mismatched_Payload, "pending with permission must fail")

    part.permission_state = nil
    testing.expect(t, tool_part_validate(part) == .None, "bare pending must validate")

    // canceled may carry an undecided permission state.
    part.state = Tool_State_Canceled{}
    part.permission_state = offered
    testing.expect(t, tool_part_validate(part) == .None, "undecided canceled must validate")
}

@(test)
test_tool_part_waiting_permission_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    // `permission` arrives before `state`; emitter order is the reverse.
    input := `{"type":"tool","id":0,"name":"read","arguments":"{}","permission":{"requested_at_ms":1,"options":[{"id":"o1","kind":"allow_once","label":"Allow"}]},"state":{"type":"waiting_permission"}}`
    emitted := `{"type":"tool","id":0,"name":"read","arguments":"{}","state":{"type":"waiting_permission"},"permission":{"requested_at_ms":1,"options":[{"id":"o1","kind":"allow_once","label":"Allow"}]}}`
    v := decoder_init(input)

    part, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    tool, ok := part.(Tool_Part)
    testing.expect(t, ok, "should be a tool part")
    _, is_waiting := tool.state.(Tool_State_Waiting_Permission)
    testing.expect(t, is_waiting, "should be a waiting_permission state")
    perm, has_perm := tool.permission_state.?
    testing.expect(t, has_perm, "permission state should be present")
    testing.expect_value(t, perm.requested_at_ms, u64(1))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), emitted)
}

// `permission` is a part-level member; a tool state object must reject it.
@(test)
test_tool_state_rejects_permission_member :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    inputs := []string {
        `{"type":"pending","permission":{"requested_at_ms":1}}`,
        `{"type":"waiting_permission","permission":{"requested_at_ms":1}}`,
        `{"type":"running","started_at_ms":1,"permission":{"requested_at_ms":1}}`,
        `{"type":"completed","output":"ok","duration_ms":1,"permission":{"requested_at_ms":1}}`,
        `{"type":"error","error":"boom","duration_ms":1,"permission":{"requested_at_ms":1}}`,
        `{"type":"denied","reason":"no","denied_by":"policy","permission":{"requested_at_ms":1}}`,
        `{"type":"canceled","permission":{"requested_at_ms":1}}`,
    }
    for input in inputs {
        v := decoder_init(input)
        _, derr := tool_state_from_reader(&v)
        testing.expect(t, derr == .Mismatched_Payload, "state-level permission must be rejected")
    }
}

// Cloning a skill-less user message must keep `skill` absent.
@(test)
test_user_message_clone_preserves_absent_skill :: proc(t: ^testing.T) {
    src := User_Message {
        id = 1,
        input_id = 1,
        content = []Content_Part{Content_Text{text = "hi"}},
        time = {created_at_ms = 1},
    }

    cloned := user_message_clone(src, context.temp_allocator)
    _, has_skill := cloned.skill.?
    testing.expect(t, !has_skill, "cloned skill must stay absent")
}

// ---------------------------------------------------------------------------
// Reasoning signatures and turn provenance
// ---------------------------------------------------------------------------

// A signed reasoning part carries its signature in the one encoding, so the log and a
// client see the same bytes.
@(test)
test_reasoning_signature_emitted :: proc(t: ^testing.T) {
    part := Assistant_Part(Reasoning_Part{id = 0, text = "hm", signature = "ErUBCkYIB"})

    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), `{"type":"reasoning","id":0,"text":"hm","signature":"ErUBCkYIB"}`)
}

// An unsigned reasoning part must not write an empty `signature`, so a provider that
// issues none produces exactly the pre-signature encoding.
@(test)
test_reasoning_signature_omitted_when_empty :: proc(t: ^testing.T) {
    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, Reasoning_Part{id = 1, text = "hm"})
    testing.expect_value(t, to_string(&e), `{"type":"reasoning","id":1,"text":"hm"}`)
}

// Rows written before the field existed decode unchanged, with no signature.
@(test)
test_reasoning_part_without_signature_decodes :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"reasoning","id":0,"text":"hm"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)

    part, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    reasoning, ok := part.(Reasoning_Part)
    testing.expect(t, ok, "should be a reasoning part")
    testing.expect_value(t, reasoning.signature, "")
}

// A signed row round-trips byte-for-byte through the persisted encoding.
@(test)
test_reasoning_signature_persisted_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"reasoning","id":2,"text":"hm","signature":"ErUBCkYIB"}`
    v := decoder_init(input)

    part, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    reasoning, ok := part.(Reasoning_Part)
    testing.expect(t, ok, "should be a reasoning part")
    testing.expect_value(t, reasoning.signature, "ErUBCkYIB")

    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), input)
}

// `signature` belongs to the reasoning arm alone; the text arm rejects it.
@(test)
test_text_part_rejects_signature :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"text","id":0,"text":"hi","signature":"ErUBCkYIB"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := assistant_part_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "signature on a text part must be rejected")
}

// The signature is borrowed like `text`, so a clone must own its own copy.
@(test)
test_reasoning_part_clone_copies_signature :: proc(t: ^testing.T) {
    src := Assistant_Part(Reasoning_Part{id = 0, text = "hm", signature = "ErUBCkYIB"})
    cloned := assistant_part_clone(src, context.temp_allocator).(Reasoning_Part)
    testing.expect_value(t, cloned.signature, "ErUBCkYIB")
    testing.expect(
        t,
        raw_data(cloned.signature) != raw_data(src.(Reasoning_Part).signature),
        "clone must not alias the source signature",
    )
}

// The signature is unbounded payload the message cap has to see.
@(test)
test_reasoning_signature_counts_toward_string_bytes :: proc(t: ^testing.T) {
    part := Assistant_Part(Reasoning_Part{id = 0, text = "hm", signature = "abcd"})
    testing.expect_value(t, _assistant_part_string_bytes(part), 6)
}

// A redacted reasoning block has its own closed arm: the opaque encrypted data
// survives persistence without being confused with a regular thinking signature.
@(test)
test_redacted_reasoning_part_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"redacted_reasoning","id":2,"data":"opaque-data"}`
    v := decoder_init(input)

    part, derr := assistant_part_from_reader(&v)
    testing.expect_value(t, derr, Validation_Error.None)
    redacted, ok := part.(Redacted_Reasoning_Part)
    testing.expect(t, ok, "should be redacted reasoning")

    if ok {
        testing.expect_value(t, redacted.id, Part_Id(2))
        testing.expect_value(t, redacted.data, "opaque-data")
    }

    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_part_emit(&e, part)
    testing.expect_value(t, to_string(&e), input)
}

// `data` is required and belongs only to the redacted-reasoning arm. Known
// sibling fields are rejected instead of being materialized or ignored.
@(test)
test_redacted_reasoning_part_rejects_mismatched_shape :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    inputs := []string {
        `{"type":"redacted_reasoning","id":0}`,
        `{"type":"redacted_reasoning","id":0,"data":"opaque","text":"not-opaque"}`,
        `{"type":"text","id":0,"text":"hi","data":"opaque"}`,
        `{"type":"reasoning","id":0,"text":"hm","data":"opaque"}`,
        `{"type":"tool","id":0,"name":"read","arguments":"{}","state":{"type":"pending"},"data":"opaque"}`,
    }
    for input in inputs {
        v := decoder_init(input)
        _, derr := assistant_part_from_reader(&v)
        testing.expect_value(t, derr, Validation_Error.Mismatched_Payload)
    }
}

// Opaque data is borrowed on decode and therefore cloned into the destination owner.
@(test)
test_redacted_reasoning_part_clone_copies_data :: proc(t: ^testing.T) {
    src := Assistant_Part(Redacted_Reasoning_Part{id = 0, data = "opaque-data"})
    cloned := assistant_part_clone(src, context.temp_allocator).(Redacted_Reasoning_Part)
    testing.expect_value(t, cloned.data, "opaque-data")
    testing.expect(
        t,
        raw_data(cloned.data) != raw_data(src.(Redacted_Reasoning_Part).data),
        "clone must not alias the source data",
    )
}

// Redacted data is unbounded payload covered by the aggregate assistant-message cap.
@(test)
test_redacted_reasoning_data_counts_toward_string_bytes :: proc(t: ^testing.T) {
    part := Assistant_Part(Redacted_Reasoning_Part{id = 0, data = "opaque"})
    testing.expect_value(t, _assistant_part_string_bytes(part), 6)
}

// The aggregate cap bounds a message on both paths, so one message always fits in a
// frame. `text` is @unbounded, so nothing else stops a single part from growing.
@(test)
test_message_string_bytes_cap_applies_to_draft_and_committed :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    oversized := strings.repeat("x", LIMITS.max_message_string_bytes + 1, context.temp_allocator)
    content := []Assistant_Part{Text_Part{id = 0, text = oversized}}

    draft := Assistant_Message {
        id = 1,
        run_id = 1,
        agent = "main",
        content = content,
        time = {created_at_ms = 1},
    }
    testing.expect_value(t, assistant_message_validate_draft(draft), Validation_Error.Overflow)

    committed := draft
    committed.finish = Stop_Reason.Stop
    committed.time = {
        created_at_ms   = 1,
        completed_at_ms = 2,
    }
    testing.expect_value(t, assistant_message_validate_committed(committed), Validation_Error.Overflow)
}

// Provenance is written in the one encoding, so the log and a client see the same bytes.
@(test)
test_turn_provenance_emitted :: proc(t: ^testing.T) {
    msg := Assistant_Message {
        id = 1,
        run_id = 1,
        config_rev = 1,
        agent = "main",
        content = []Assistant_Part{},
        finish = Stop_Reason.Stop,
        time = {created_at_ms = 1, completed_at_ms = 2},
        provenance = Turn_Provenance{protocol = .Anthropic_Messages, model = "claude-sonnet-4-5"},
    }
    testing.expect(t, assistant_message_validate(msg) == .None, "provenance should validate")

    tail := `,"finish":"stop","time":{"created_at_ms":1,"completed_at_ms":2}`
    head := `{"type":"assistant","id":1,"run_id":1,"config_rev":1,"agent":"main","content":[]`

    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_message_emit(&e, msg)
    expected := strings.concatenate(
        {head, tail, `,"provenance":{"protocol":"anthropic-messages","model":"claude-sonnet-4-5"}}`},
        context.temp_allocator,
    )
    testing.expect_value(t, to_string(&e), expected)
}

// Assistant messages logged before the field existed decode with no provenance.
@(test)
test_assistant_message_without_provenance_decodes :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"assistant","id":1,"run_id":1,"config_rev":1,"agent":"main","content":[],"finish":"stop","time":{"created_at_ms":1,"completed_at_ms":2}}`
    v := decoder_init(input)

    msg, derr := assistant_message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, has_prov := msg.provenance.?
    testing.expect(t, !has_prov, "provenance must stay absent")

    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

// A logged provenance round-trips byte-for-byte.
@(test)
test_turn_provenance_persisted_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"assistant","id":1,"run_id":1,"config_rev":1,"agent":"main","content":[],"finish":"stop","time":{"created_at_ms":1,"completed_at_ms":2},"provenance":{"protocol":"openai-completions","model":"gpt-5"}}`
    v := decoder_init(input)

    msg, derr := assistant_message_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    prov, has_prov := msg.provenance.?
    testing.expect(t, has_prov, "provenance should be present")
    testing.expect_value(t, prov.protocol, Provider_Protocol.Openai_Chat)
    testing.expect_value(t, prov.model, "gpt-5")

    e: Emitter
    emitter_init(&e, context.temp_allocator)
    defer emitter_destroy(&e)
    assistant_message_emit(&e, msg)
    testing.expect_value(t, to_string(&e), input)
}

// The protocol set is closed; an unknown name is not silently kept.
@(test)
test_turn_provenance_rejects_unknown_protocol :: proc(t: ^testing.T) {
    v := decoder_init(`{"protocol":"gemini","model":"x"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := turn_provenance_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "unknown protocol must be rejected")
}

// Both members are required once the object is present.
@(test)
test_turn_provenance_requires_both_members :: proc(t: ^testing.T) {
    v := decoder_init(`{"protocol":"anthropic-messages"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := turn_provenance_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "provenance without a model must be rejected")
}

// Provenance is assistant-only; the sibling message arms reject it.
@(test)
test_provenance_rejected_on_sibling_messages :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    inputs := []string {
        `{"type":"user","id":1,"input_id":1,"content":[],"time":{"created_at_ms":1},"provenance":{"protocol":"anthropic-messages","model":"m"}}`,
        `{"type":"compaction","id":1,"run_id":1,"reason":"auto","summary":"s","first_kept_id":null,"tokens_before":1,"tokens_after":1,"time":{"created_at_ms":1},"provenance":{"protocol":"anthropic-messages","model":"m"}}`,
    }
    for input in inputs {
        v := decoder_init(input)
        _, derr := message_from_reader(&v)
        testing.expect(t, derr == .Mismatched_Payload, "provenance on a non-assistant message must be rejected")
    }
}

// The clone owns its model string, like every other borrowed member.
@(test)
test_turn_provenance_clone_copies_model :: proc(t: ^testing.T) {
    src := Turn_Provenance {
        protocol = .Anthropic_Messages,
        model    = "claude-sonnet-4-5",
    }
    cloned := turn_provenance_clone(src, context.temp_allocator)
    testing.expect_value(t, cloned.protocol, Provider_Protocol.Anthropic_Messages)
    testing.expect_value(t, cloned.model, "claude-sonnet-4-5")
    testing.expect(t, raw_data(cloned.model) != raw_data(src.model), "clone must not alias the source model")
}
