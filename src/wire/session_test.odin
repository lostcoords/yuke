package wire

import "core:strings"
import "core:testing"

@(private = "file")
_fixed16 :: proc(s: string) -> [16]u8 {
    out: [16]u8
    for i in 0 ..< 16 {
        out[i] = s[i]
    }

    return out
}

@(private = "file")
_sample_session_list_item :: proc() -> Session_List_Item {
    return Session_List_Item {
        session = Session {
            id = Session_Id(_fixed16("0123456789abcdef")),
            workspace_id = Workspace_Id(_fixed16("aaaaaaaaaaaaaaaa")),
            profile = "default",
            model = "openai/gpt",
            reasoning = "low",
            config_rev = Config_Rev(1),
            permission = .Normal,
            max_rounds = nil,
            title = "title",
            message_count = 0,
            updated_at_ms = 1,
            created_by = Client{name = "test", version = "0"},
            origin = Session_Origin_Root{},
        },
        activity = Session_Activity {
            state = Activity_State_Idle{},
            queued = 0,
            context_tokens = 0,
            pending_compaction = nil,
        },
    }
}

@(test)
test_session_scope_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"workspace","workspace_id":"aaaaaaaaaaaaaaaa"}`
    v := decoder_init(input, context.temp_allocator)

    scope, derr := session_scope_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    ws, ok := scope.(Session_Scope_Workspace)
    testing.expect(t, ok, "should be a workspace scope")
    wid := ([16]u8)(ws.workspace_id)
    testing.expect_value(t, string(wid[:]), "aaaaaaaaaaaaaaaa")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_scope_emit(&e, scope)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_scope_rejects_sibling :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"all","workspace_id":"aaaaaaaaaaaaaaaa"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := session_scope_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "sibling field must be rejected")
}

@(test)
test_session_population_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"children","parent_id":"0123456789abcdef"}`
    v := decoder_init(input, context.temp_allocator)

    pop, derr := session_population_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    children, ok := pop.(Session_Population_Children)
    testing.expect(t, ok, "should be a children population")
    pid := ([16]u8)(children.parent_id)
    testing.expect_value(t, string(pid[:]), "0123456789abcdef")
    testing.expect(t, session_population_validate(pop) == .None, "valid population")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_population_emit(&e, pop)
    testing.expect_value(t, to_string(&e), input)

    // Invalid hex in the parent id fails validation.
    invalid := Session_Population_Children {
        parent_id = Session_Id(_fixed16("g123456789abcdef")),
    }
    testing.expect(t, session_population_validate(Session_Population(invalid)) == .Invalid_Hex, "non-hex id rejected")

    // A sibling arm's field is rejected.
    v2 := decoder_init(`{"type":"top_level","parent_id":"0123456789abcdef"}`, context.temp_allocator)
    _, derr2 := session_population_from_reader(&v2)
    testing.expect(t, derr2 == .Mismatched_Payload, "sibling field must be rejected")
}

@(test)
test_session_origin_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    root_v := decoder_init(`{"type":"root"}`, context.temp_allocator)
    root, rderr := session_origin_from_reader(&root_v)
    testing.expect(t, rderr == .None, "decode should succeed")
    _, is_root := root.(Session_Origin_Root)
    testing.expect(t, is_root, "should be a root origin")

    input := `{"type":"child","parent_id":"0123456789abcdef","parent_message_id":3,"parent_part_id":1}`
    child_v := decoder_init(input, context.temp_allocator)
    child, cderr := session_origin_from_reader(&child_v)
    testing.expect(t, cderr == .None, "decode should succeed")
    ch, is_child := child.(Session_Origin_Child)
    testing.expect(t, is_child, "should be a child origin")
    pid := ([16]u8)(ch.parent_id)
    testing.expect_value(t, string(pid[:]), "0123456789abcdef")
    testing.expect_value(t, u64(ch.parent_message_id), u64(3))
    testing.expect_value(t, u64(ch.parent_part_id), u64(1))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_origin_emit(&e, child)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_origin_rejects_sibling :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"root","parent_id":"0123456789abcdef"}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := session_origin_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "field outside active tag must be rejected")
}

@(test)
test_session_origin_child_rejects_missing_locator :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"type":"child","parent_id":"0123456789abcdef","parent_message_id":3}`, context.temp_allocator)
    _, derr := session_origin_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "missing parent_part_id must be rejected")

    v2 := decoder_init(`{"type":"root","parent_message_id":3,"parent_part_id":1}`, context.temp_allocator)
    _, derr2 := session_origin_from_reader(&v2)
    testing.expect(t, derr2 == .Mismatched_Payload, "child-only locator fields rejected on sibling arm")
}

@(test)
test_session_created_by_matches_origin :: proc(t: ^testing.T) {
    item := _sample_session_list_item()

    item.session.created_by = nil
    testing.expect(t, session_validate(item.session) == .Mismatched_Payload, "root without creator rejected")

    item.session.origin = Session_Origin_Child {
        parent_id         = Session_Id(_fixed16("1111111111111111")),
        parent_message_id = Message_Id(1),
        parent_part_id    = Part_Id(0),
    }
    testing.expect(t, session_validate(item.session) == .None, "daemon-created child with null creator accepted")

    item.session.created_by = Client {
        name    = "test",
        version = "0",
    }
    testing.expect(t, session_validate(item.session) == .Mismatched_Payload, "child with creator rejected")
}

@(test)
test_session_accepts_null_attribution_for_child :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"id":"0123456789abcdef","workspace_id":"aaaaaaaaaaaaaaaa","profile":"default","model":"openai/gpt","reasoning":"high","config_rev":1,"permission":"normal","max_rounds":null,"title":"child","message_count":0,"updated_at_ms":1,"created_by":null,"origin":{"type":"child","parent_id":"1111111111111111","parent_message_id":1,"parent_part_id":0}}`
    v := decoder_init(input, context.temp_allocator)

    session, derr := session_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, has_creator := session.created_by.?
    testing.expect(t, !has_creator, "created_by should be null")
    testing.expect(t, session_validate(session) == .None, "daemon-created child validates")
}

@(test)
test_session_agent_omitted_when_absent :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    item := _sample_session_list_item()

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_emit(&e, item.session)
    out := to_string(&e)
    testing.expect(t, !strings.contains(out, "\"agent\""), "agent must be omitted when absent")
}

@(test)
test_session_agent_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    item := _sample_session_list_item()
    item.session.agent = "worker"

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_emit(&e, item.session)
    out := to_string(&e)

    v := decoder_init(out, context.temp_allocator)
    decoded, derr := session_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    agent, ok := decoded.agent.?
    testing.expect(t, ok, "agent should be present")
    testing.expect_value(t, agent, "worker")
    testing.expect(t, session_validate(decoded) == .None, "agent within bound validates")
}

@(test)
test_session_agent_rejects_oversized :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    item := _sample_session_list_item()
    item.session.agent = strings.repeat("a", 65, context.temp_allocator)
    testing.expect(t, session_validate(item.session) == .Overflow, "oversized agent must overflow")
}

@(test)
test_session_list_params_defaults :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(`{}`, context.temp_allocator)

    params, derr := session_list_params_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, is_all := params.scope.(Session_Scope_All)
    testing.expect(t, is_all, "scope defaults to all")
    _, is_top := params.population.(Session_Population_Top_Level)
    testing.expect(t, is_top, "population defaults to top_level")
    testing.expect_value(t, params.view, Session_View.Active_Recent)
    _, has_limit := params.limit.?
    testing.expect(t, !has_limit, "limit defaults absent")
    _, has_cursor := params.cursor.?
    testing.expect(t, !has_cursor, "cursor defaults absent")
    testing.expect(t, session_list_params_validate(params) == .None, "defaults validate")

    bad := params
    bad.limit = u64(0)
    testing.expect(t, session_list_params_validate(bad) == .Out_Of_Range, "zero limit rejected")
    bad.limit = u64(LIMITS.max_session_list_page_size + 1)
    testing.expect(t, session_list_params_validate(bad) == .Out_Of_Range, "oversized limit rejected")

    over := params
    over.cursor = strings.repeat("x", LIMITS.max_session_list_cursor_bytes + 1, context.temp_allocator)
    testing.expect(t, session_list_params_validate(over) == .Overflow, "oversized cursor rejected")
}

@(test)
test_session_list_result_validate :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"revision":0,"items":[],"next_cursor":null,"total":0}`, context.temp_allocator)
    result, derr := session_list_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect(t, session_list_result_validate(result) == .None, "empty page validates")

    over_rev := result
    over_rev.revision = Session_Revision(MAX_SESSION_REVISION + 1)
    testing.expect(t, session_list_result_validate(over_rev) == .Out_Of_Range, "oversized revision rejected")

    over_cursor := result
    over_cursor.next_cursor = strings.repeat("x", LIMITS.max_session_list_cursor_bytes + 1, context.temp_allocator)
    testing.expect(t, session_list_result_validate(over_cursor) == .Overflow, "oversized cursor rejected")

    fewer := result
    fewer.items = []Session_List_Item{_sample_session_list_item()}
    fewer.total = 0
    testing.expect(t, session_list_result_validate(fewer) == .Mismatched_Payload, "total below page count rejected")
}

@(test)
test_session_activity_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"state":{"type":"idle"},"queued":0,"context_tokens":0,"pending_compaction":null}`
    v := decoder_init(input, context.temp_allocator)

    activity, derr := session_activity_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, is_idle := activity.state.(Activity_State_Idle)
    testing.expect(t, is_idle, "state should be idle")
    testing.expect(t, session_activity_validate(activity) == .None, "idle activity validates")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_activity_emit(&e, activity)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_activity_state_running_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"running","run_id":1,"started_at_ms":1720000000000}`
    v := decoder_init(input, context.temp_allocator)

    state, derr := activity_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    running, ok := state.(Activity_State_Running)
    testing.expect(t, ok, "should be a running state")
    testing.expect_value(t, u64(running.run_id), u64(1))
    testing.expect_value(t, running.started_at_ms, u64(1720000000000))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    activity_state_emit(&e, state)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_activity_state_building_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"type":"building","run_id":1,"started_at_ms":1720000000000}`
    v := decoder_init(input, context.temp_allocator)

    state, derr := activity_state_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    _, ok := state.(Activity_State_Building)
    testing.expect(t, ok, "should be a building state")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    activity_state_emit(&e, state)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_activity_state_rejects_sibling :: proc(t: ^testing.T) {
    v := decoder_init(`{"type":"idle","run_id":1}`, context.temp_allocator)
    defer free_all(context.temp_allocator)
    _, derr := activity_state_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "field outside active tag must be rejected")
}

// A list row resolves its running config without any `configs` table on the result.
@(test)
test_session_list_item_carries_activity_config :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    item := _sample_session_list_item()
    item.activity.state = Activity_State_Running {
        run_id        = Run_Id(7),
        started_at_ms = 1,
    }
    item.activity.config = Run_Config {
        config_rev = Config_Rev(2),
        model      = "openai/gpt-5.5",
        reasoning  = "high",
    }
    testing.expect(t, session_list_item_validate(item) == .None, "running row validates")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_list_item_emit(&e, item)

    v := decoder_init(to_string(&e), context.temp_allocator)
    decoded, derr := session_list_item_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    cfg, has_config := decoded.activity.config.?
    testing.expect(t, has_config, "list row carries its own config")
    testing.expect_value(t, u64(cfg.config_rev), u64(2))
    testing.expect_value(t, cfg.model, "openai/gpt-5.5")
}

@(test)
test_session_activity_config_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"state":{"type":"running","run_id":7,"started_at_ms":1},"config":{"config_rev":2,"model":"openai/gpt-5.5","reasoning":"high"},"queued":0,"context_tokens":0,"pending_compaction":null}`
    v := decoder_init(input, context.temp_allocator)

    activity, derr := session_activity_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    cfg, has_config := activity.config.?
    testing.expect(t, has_config, "hoisted config should be present")
    testing.expect_value(t, u64(cfg.config_rev), u64(2))
    testing.expect_value(t, cfg.model, "openai/gpt-5.5")
    testing.expect_value(t, cfg.reasoning, "high")
    testing.expect(t, session_activity_validate(activity) == .None, "running activity with config validates")

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    session_activity_emit(&e, activity)
    testing.expect_value(t, to_string(&e), input)

    // `config` trails `pending_compaction`; emitter order is the reverse.
    permuted := `{"state":{"type":"running","run_id":7,"started_at_ms":1},"queued":0,"context_tokens":0,"pending_compaction":null,"config":{"config_rev":2,"model":"openai/gpt-5.5","reasoning":"high"}}`
    pv := decoder_init(permuted, context.temp_allocator)

    reordered, perr := session_activity_from_reader(&pv)
    testing.expect(t, perr == .None, "config-last activity should decode")

    pe: Emitter
    emitter_init(&pe)
    defer emitter_destroy(&pe)
    session_activity_emit(&pe, reordered)
    testing.expect_value(t, to_string(&pe), input)
}

@(test)
test_session_activity_config_cross_field :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    cfg := Run_Config {
        config_rev = Config_Rev(1),
        model      = "model",
        reasoning  = "low",
    }

    Case :: struct {
        state:          Activity_State,
        config_present: bool,
        tag:            string,
    }

    cases := []Case {
        {Activity_State_Idle{}, false, "idle"},
        {Activity_State_Building{run_id = Run_Id(1), started_at_ms = 1}, true, "building"},
        {Activity_State_Running{run_id = Run_Id(1), started_at_ms = 1}, true, "running"},
        {
            Activity_State_Reasoning{run_id = Run_Id(1), message_id = Message_Id(2), part_id = Part_Id(0)},
            true,
            "reasoning",
        },
        {
            Activity_State_Waiting_Permission {
                run_id = Run_Id(1),
                message_id = Message_Id(2),
                part_id = Part_Id(0),
                tool_name = "read",
                requested_at_ms = 1,
            },
            true,
            "waiting_permission",
        },
        {
            Activity_State_Running_Tool {
                run_id = Run_Id(1),
                message_id = Message_Id(2),
                part_id = Part_Id(0),
                tool_name = "read",
                started_at_ms = 1,
            },
            true,
            "running_tool",
        },
        {
            Activity_State_Retrying {
                run_id = Run_Id(1),
                attempt = 1,
                max_attempts = 2,
                next_at_ms = 3,
                code = .Provider,
                message = "boom",
            },
            true,
            "retrying",
        },
        {Activity_State_Compacting{run_id = Run_Id(1), reason = .Manual, started_at_ms = 1}, false, "compacting"},
    }

    for c in cases {
        with_config := Session_Activity {
            state  = c.state,
            config = cfg,
        }
        without_config := Session_Activity {
            state = c.state,
        }

        if c.config_present {
            testing.expect(t, session_activity_validate(with_config) == .None, c.tag)
            testing.expect(t, session_activity_validate(without_config) == .Mismatched_Payload, c.tag)
        } else {
            testing.expect(t, session_activity_validate(with_config) == .Mismatched_Payload, c.tag)
            testing.expect(t, session_activity_validate(without_config) == .None, c.tag)
        }
    }

    over := Session_Activity {
        state = Activity_State_Running{run_id = Run_Id(1), started_at_ms = 1},
    }
    over.config = Run_Config {
        config_rev = Config_Rev(1),
        model      = strings.repeat("x", 129, context.temp_allocator),
        reasoning  = "low",
    }
    testing.expect(t, session_activity_validate(over) == .Overflow, "oversized hoisted config model rejected")
}

@(test)
test_activity_state_rejects_hoisted_config :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    inputs := []string {
        `{"type":"building","run_id":1,"config":{"config_rev":1,"model":"m","reasoning":"low"},"started_at_ms":1}`,
        `{"type":"running","run_id":1,"config":{"config_rev":1,"model":"m","reasoning":"low"},"started_at_ms":1}`,
        `{"type":"reasoning","run_id":1,"config":{"config_rev":1,"model":"m","reasoning":"low"},"message_id":1,"part_id":0}`,
        `{"type":"waiting_permission","run_id":1,"config":{"config_rev":1,"model":"m","reasoning":"low"},"message_id":1,"part_id":0,"tool_name":"read","requested_at_ms":1}`,
        `{"type":"running_tool","run_id":1,"config":{"config_rev":1,"model":"m","reasoning":"low"},"message_id":1,"part_id":0,"tool_name":"read","started_at_ms":1}`,
        `{"type":"retrying","run_id":1,"config":{"config_rev":1,"model":"m","reasoning":"low"},"attempt":1,"max_attempts":2,"next_at_ms":3,"code":"provider","message":"boom"}`,
    }

    for input in inputs {
        v := decoder_init(input, context.temp_allocator)
        _, derr := activity_state_from_reader(&v)
        testing.expect(t, derr == .Mismatched_Payload, "config inside an activity arm must be rejected")
    }
}

@(test)
test_activity_state_retry_bounded :: proc(t: ^testing.T) {
    defer free_all(context.temp_allocator)

    at_cap := strings.repeat("x", LIMITS.max_activity_retry_message_bytes, context.temp_allocator)
    valid := Activity_State_Retrying {
        run_id       = Run_Id(1),
        attempt      = 1,
        max_attempts = 2,
        next_at_ms   = 3,
        code         = .Provider,
        message      = at_cap,
    }
    testing.expect(t, activity_state_validate(Activity_State(valid)) == .None, "retry message at cap validates")

    over := valid
    over.message = strings.repeat("x", LIMITS.max_activity_retry_message_bytes + 1, context.temp_allocator)
    testing.expect(t, activity_state_validate(Activity_State(over)) == .Overflow, "oversized retry message rejected")
}

@(test)
test_create_session_omitted_vs_explicit :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"workspace_path":"/repo","system_prompt":null,"max_rounds":4}`, context.temp_allocator)
    cs, derr := create_session_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, cs.workspace_path, "/repo")
    _, is_none := cs.system_prompt.(System_Prompt_None)
    testing.expect(t, is_none, "explicit null system_prompt is the none arm")
    set, is_set := cs.max_rounds.(Max_Rounds_Set)
    testing.expect(t, is_set, "explicit max_rounds is the set arm")
    testing.expect_value(t, set.value, u64(4))

    v2 := decoder_init(`{"workspace_path":"/repo"}`, context.temp_allocator)
    omitted, derr2 := create_session_from_reader(&v2)
    testing.expect(t, derr2 == .None, "decode should succeed")
    _, sp_default := omitted.system_prompt.(System_Prompt_Default)
    testing.expect(t, sp_default, "omitted system_prompt is the default arm")
    _, mr_default := omitted.max_rounds.(Max_Rounds_Default)
    testing.expect(t, mr_default, "omitted max_rounds is the default arm")
}

@(test)
test_session_patch_bounds :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    v := decoder_init(`{"model":"openai/gpt","reasoning":"high"}`, context.temp_allocator)
    patch, derr := session_patch_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect(t, session_patch_validate(patch) == .None, "bounded patch validates")

    over := patch
    over.model = strings.repeat("m", 129, context.temp_allocator)
    testing.expect(t, session_patch_validate(over) == .Overflow, "oversized model rejected")
}

@(test)
test_compact_result_roundtrip :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)

    input := `{"status":"queued","run_id":3}`
    v := decoder_init(input, context.temp_allocator)
    result, derr := compact_result_from_reader(&v)
    testing.expect(t, derr == .None, "decode should succeed")
    testing.expect_value(t, result.status, Compact_Status.Queued)
    testing.expect_value(t, u64(result.run_id), u64(3))

    e: Emitter
    emitter_init(&e)
    defer emitter_destroy(&e)
    compact_result_emit(&e, result)
    testing.expect_value(t, to_string(&e), input)
}

@(test)
test_session_rejects_missing_created_by :: proc(t: ^testing.T) {
    // `created_by` is required-but-nullable: an explicit null is fine, an absent
    // key is not (it is always emitted).
    input := `{"id":"0123456789abcdef","workspace_id":"aaaaaaaaaaaaaaaa","profile":"default","model":"openai/gpt","reasoning":"high","config_rev":1,"permission":"normal","max_rounds":null,"title":"child","message_count":0,"updated_at_ms":1,"origin":{"type":"child","parent_id":"1111111111111111","parent_message_id":1,"parent_part_id":0}}`
    context.allocator = context.temp_allocator
    defer free_all(context.temp_allocator)
    v := decoder_init(input, context.temp_allocator)
    _, derr := session_from_reader(&v)
    testing.expect(t, derr == .Mismatched_Payload, "missing created_by must be rejected")
}
