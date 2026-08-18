package daemon

import "core:fmt"
import "core:mem/virtual"
import "core:nbio"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "src:daemon/catalog"
import "src:provider"
import "src:wire"

// Live provider turns are opt-in: they need a real key and a network, so they never run
// in the ordinary gates. Enable with `-define:YUKE_LIVE=true`.
LIVE :: #config(YUKE_LIVE, false)

@(private = "file")
LIVE_KEY_ENV :: "MINIMAX_API_KEY"

@(private = "file")
LIVE_TIMEOUT :: 90 * time.Second

@(private = "file")
Live_Turn :: struct {
    t:         ^testing.T,
    text:      strings.Builder,
    reasoning: strings.Builder,
    blocks:    int,
    // Cloned: the block's strings die with the frame that carried them.
    tool_name: string,
    tool_args: string,
    result:    provider.Turn_Result,
    reason:    provider.Stop_Reason,
    done:      bool,
}

// The MiniMax rows exactly as the catalog resolves them, so a live turn exercises the
// same request assembly a real run would. Verified against `yuke catalog list`.
@(private = "file")
live_model :: proc(upstream: string, levels: []string, adaptive: bool) -> catalog.Model {
    return catalog.Model {
        info = {
            id = wire.Model_Id(strings.concatenate({"minimax/", upstream}, context.temp_allocator)),
            provider = "minimax",
            name = upstream,
            context_window = 204_800,
            max_output_tokens = 2048,
            reasoning_levels = levels,
            default_reasoning = catalog.default_reasoning_level(levels),
            supports_tools = true,
        },
        upstream_id = upstream,
        endpoint = {base_url = "https://api.minimax.io/anthropic/v1", protocol = .Anthropic_Messages},
        supports_temperature = true,
        anthropic_adaptive = adaptive,
    }
}

@(private = "file")
live_on_event :: proc(user: rawptr, event: provider.Stream_Event) {
    turn := (^Live_Turn)(user)

    #partial switch value in event {
    case provider.Stream_Block_Started:
        turn.blocks += 1

    case provider.Stream_Text_Delta:
        strings.write_string(&turn.text, value.text)

    case provider.Stream_Reasoning_Delta:
        strings.write_string(&turn.reasoning, value.text)

    case provider.Stream_Block_Stopped:
        if tool, is_tool := value.result.(provider.Stream_Tool_Block); is_tool {
            turn.tool_name = strings.clone(tool.call.name, context.allocator)
            turn.tool_args = strings.clone(tool.call.arguments, context.allocator)
        }

    case provider.Stream_Done:
        turn.reason = value.reason
    }
}

@(private = "file")
live_on_done :: proc(user: rawptr, result: provider.Turn_Result) {
    turn := (^Live_Turn)(user)
    turn.result = result
    turn.done = true
}

// Drive one real turn to completion and report what came back.
@(private = "file")
live_turn_run :: proc(
    t: ^testing.T,
    model: ^catalog.Model,
    reasoning: string,
    prompt: string,
    tools: []provider.Tool_Definition = nil,
) -> Live_Turn {
    key, has_key := os.lookup_env(LIVE_KEY_ENV, context.allocator)
    testing.expectf(t, has_key, "%s must be set for a live turn", LIVE_KEY_ENV)
    if !has_key do return {}
    defer delete(key, context.allocator)

    testing.expect_value(t, nbio.acquire_thread_event_loop(), nil)
    defer nbio.release_thread_event_loop()
    loop := nbio.current_thread_event_loop()

    service: Run_Service
    testing.expect_value(t, run_service_init(&service, loop, context.allocator), Error.None)
    defer run_service_destroy(&service)

    arena: virtual.Arena
    testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
    defer virtual.arena_destroy(&arena)
    scratch := virtual.arena_allocator(&arena)

    messages := [?]wire.Message {
        wire.User_Message{id = 1, content = []wire.Content_Part{wire.Content_Text{text = prompt}}, input_id = 1},
    }
    connection := provider.Connection {
        endpoint = model.endpoint,
        auth = provider.Api_Key{key = key},
    }

    body, build_err := run_request_build(
        model,
        connection.auth,
        reasoning,
        {messages = messages[:], tools = tools},
        scratch,
        scratch,
    )
    testing.expect_value(t, build_err, provider.Transport_Error.None)
    if build_err != .None do return {}
    fmt.eprintfln("[live] %s level=%q body=%s", model.upstream_id, reasoning, body)

    turn := Live_Turn {
        t = t,
    }
    turn.text = strings.builder_make(context.allocator)
    turn.reasoning = strings.builder_make(context.allocator)

    op := run_begin(&service, connection, body, {on_event = live_on_event, on_done = live_on_done, user = &turn})
    testing.expect(t, op != nil, "the live turn started")
    if op == nil do return turn

    deadline := nbio.timeout_poly(LIVE_TIMEOUT, &turn, proc(_: ^nbio.Operation, turn: ^Live_Turn) {
            testing.expect(turn.t, false, "the live turn timed out")
            turn.done = true
        }, loop)
    nbio.run_until(&turn.done)
    nbio.remove(deadline)

    if run_service_busy(&service) {
        run_service_shutdown(&service)
        run_cancel(&service, op)
    }

    return turn
}

@(test)
test_live_minimax_text_turn :: proc(t: ^testing.T) {
    when !LIVE {
        return
    }

    // M2.7 advertises no reasoning options, so no thinking control is sent. It thinks
    // anyway — the endpoint cannot disable it — which exercises the reasoning decode.
    model := live_model("MiniMax-M2.7", nil, false)
    turn := live_turn_run(t, &model, "", "Reply with exactly: ok")
    defer strings.builder_destroy(&turn.text)
    defer strings.builder_destroy(&turn.reasoning)

    text := strings.to_string(turn.text)
    fmt.eprintfln("[live] reason=%v text=%q reasoning=%q", turn.reason, text, strings.to_string(turn.reasoning))

    fmt.eprintfln("[live] reason=%v tool=%q args=%s", turn.reason, turn.tool_name, turn.tool_args)

    testing.expect_value(t, turn.result.err, provider.Transport_Error.None)
    testing.expect(t, turn.blocks > 0, "the turn produced at least one block")
    testing.expect(t, len(text) > 0, "the turn produced assistant text")
}

@(test)
test_live_minimax_reasoning_turn :: proc(t: ^testing.T) {
    when !LIVE {
        return
    }

    // M3 maps a models.dev toggle onto Anthropic_Adaptive, so `high` sends
    // thinking:{"type":"adaptive"} and `off` sends thinking:{"type":"disabled"}.
    levels := [?]string{"off", "high"}
    model := live_model("MiniMax-M3", levels[:], true)

    thinking := live_turn_run(t, &model, "high", "What is 17 * 23? Answer with the number only.")
    defer strings.builder_destroy(&thinking.text)
    defer strings.builder_destroy(&thinking.reasoning)
    fmt.eprintfln(
        "[live] adaptive reason=%v text=%q reasoning=%q",
        thinking.reason,
        strings.to_string(thinking.text),
        strings.to_string(thinking.reasoning),
    )
    testing.expect_value(t, thinking.result.err, provider.Transport_Error.None)
    testing.expect(t, len(strings.to_string(thinking.reasoning)) > 0, "adaptive thinking returns reasoning text")

    off := live_turn_run(t, &model, "off", "What is 17 * 23? Answer with the number only.")
    defer strings.builder_destroy(&off.text)
    defer strings.builder_destroy(&off.reasoning)
    fmt.eprintfln(
        "[live] disabled reason=%v text=%q reasoning=%q",
        off.reason,
        strings.to_string(off.text),
        strings.to_string(off.reasoning),
    )
    testing.expect_value(t, off.result.err, provider.Transport_Error.None)
    testing.expect(t, len(strings.to_string(off.reasoning)) == 0, "disabled thinking returns no reasoning text")
    testing.expect(t, len(strings.to_string(off.text)) > 0, "disabled thinking still answers")
}

// The registry reaches a real provider: the model is offered one tool and asks for it. This
// is the checkpoint for step 8b — nothing executes the call yet.
@(test)
test_live_minimax_tool_call :: proc(t: ^testing.T) {
    when !LIVE {
        return
    }

    tools := [?]provider.Tool_Definition {
        {
            name = "get_weather",
            description = "Report the current weather for a city",
            input_schema = `{"type":"object","properties":{"city":{"type":"string"}},"required":["city"],"additionalProperties":false}`,
        },
    }

    model := live_model("MiniMax-M2.7", nil, false)
    turn := live_turn_run(t, &model, "", "What is the weather in Tokyo? Use the tool.", tools[:])
    defer strings.builder_destroy(&turn.text)
    defer strings.builder_destroy(&turn.reasoning)
    defer delete(turn.tool_name)
    defer delete(turn.tool_args)

    fmt.eprintfln("[live] reason=%v tool=%q args=%s", turn.reason, turn.tool_name, turn.tool_args)

    testing.expect_value(t, turn.result.err, provider.Transport_Error.None)
    testing.expect_value(t, turn.reason, provider.Stop_Reason.Tool_Calls)
    testing.expect_value(t, turn.tool_name, "get_weather")
    testing.expectf(t, strings.contains(turn.tool_args, "Tokyo"), "arguments should name the city: %s", turn.tool_args)
}
