package catalog

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

import "libs:json"
import "src:provider"
import "src:wire"

OPENAI_BASE_URL :: "https://api.openai.com/v1"
ANTHROPIC_BASE_URL :: "https://api.anthropic.com/v1"

Normalize_Error :: enum {
    None,
    Filtered,
    Unsupported,
    Invalid,
}

Reasoning_Option_Kind :: enum {
    None,
    Effort,
    Budget_Tokens,
    Toggle,
}

Reasoning_Spec :: struct {
    levels:      [wire.LIMITS.max_reasoning_levels]string,
    level_count: int,
    format:      provider.Openai_Thinking_Format,
    adaptive:    bool,
    budget_min:  Maybe(i64),
    budget_max:  Maybe(u64),
}

// Decode selected models.dev providers. The complete input is borrowed for the call;
// successful output is owned by allocator and must be passed to result_destroy.
decode :: proc(data: []byte, selections: []Selection, allocator := context.allocator) -> (result: Result, err: Error) {
    assert(allocator.procedure != nil, "catalog decode needs an owned allocator")
    result.allocator = allocator
    result.providers.allocator = allocator
    result.issues.allocator = allocator
    defer if err != .None {
        result_destroy(&result)
    }

    if !selections_valid(selections) {
        return result, .Invalid_Selection
    }

    if len(data) > FEED_MAX_BYTES {
        return result, .Response_Too_Large
    }

    syntax := json.make_parser(data, .JSON, true, mem.nil_allocator())
    if !json.validate_value(&syntax) || syntax.curr_token.kind != .EOF {
        return result, .Invalid_Json
    }

    scratch: virtual.Arena
    _ = virtual.arena_init_growing(&scratch)
    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    selected := make([]json.Object, len(selections), sa)
    found := make([]bool, len(selections), sa)

    parser := json.make_parser(data, .JSON, true, sa)
    if parser.curr_token.kind != .Open_Brace {
        return result, .Invalid_Json
    }
    json.advance_token(&parser)

    first := true
    for parser.curr_token.kind != .Close_Brace {
        if !first {
            if parser.curr_token.kind != .Comma {
                return result, .Invalid_Json
            }
            json.advance_token(&parser)
        }
        first = false

        key := decode_object_key(&parser) or_return
        if parser.curr_token.kind != .Colon {
            return result, .Invalid_Json
        }
        json.advance_token(&parser)

        wanted := false
        for selection, i in selections {
            if selection.source_id != key {
                continue
            }

            if found[i] {
                return result, .Invalid_Json
            }
            wanted = true
        }

        if !wanted {
            skip_value(&parser) or_return
            continue
        }

        value, parse_err := json.parse_value(&parser)
        if parse_err != nil {
            return result, .Invalid_Json
        }

        object, object_ok := value.(json.Object)
        if !object_ok {
            for selection, i in selections {
                if selection.source_id == key {
                    found[i] = true
                }
            }
            continue
        }

        for selection, i in selections {
            if selection.source_id == key {
                found[i] = true
                selected[i] = object
            }
        }
    }
    json.advance_token(&parser)
    if parser.curr_token.kind != .EOF {
        return result, .Invalid_Json
    }

    model_count := 0
    for selection, i in selections {
        if !found[i] {
            issue_append(&result, selection, .Missing)
            continue
        }

        if selected[i] == nil {
            issue_append(&result, selection, .Invalid)
            continue
        }

        item: Provider
        normalize_err := provider_normalize(&item, selection, selected[i], allocator)
        switch normalize_err {
        case .None:
            if len(item.models) > wire.LIMITS.max_catalog_models - model_count {
                provider_destroy(&item, allocator)
                return result, .Too_Many_Models
            }
            model_count += len(item.models)

            append(&result.providers, item)

        case .Unsupported:
            issue_append(&result, selection, .Unsupported)

        case .Invalid, .Filtered:
            issue_append(&result, selection, .Invalid)
        }
    }

    return result, .None
}

@(private)
selections_valid :: proc(selections: []Selection) -> bool {
    if len(selections) > SELECTIONS_MAX {
        return false
    }

    for selection, i in selections {
        if wire.provider_id_validate(selection.provider_id) != .None ||
           wire.provider_id_validate(selection.source_id) != .None {
            return false
        }

        for previous in selections[:i] {
            if previous.provider_id == selection.provider_id {
                return false
            }
        }
    }

    return true
}

@(private)
decode_object_key :: proc(parser: ^json.Parser) -> (string, Error) {
    assert(parser != nil, "catalog object key decode needs a parser")

    token := parser.curr_token
    if token.kind != .String {
        return "", .Invalid_Json
    }
    json.advance_token(parser)

    key, key_err := json.unquote_string(token, .JSON, parser.allocator)
    if key_err != nil {
        return "", .Invalid_Json
    }

    return key, .None
}

@(private)
skip_value :: proc(parser: ^json.Parser) -> Error {
    assert(parser != nil, "catalog skip needs a parser")

    #partial switch parser.curr_token.kind {
    case .Open_Brace, .Open_Bracket:
        depth := 0
        for {
            #partial switch parser.curr_token.kind {
            case .Open_Brace, .Open_Bracket:
                depth += 1

            case .Close_Brace, .Close_Bracket:
                depth -= 1

            case .EOF:
                return .Invalid_Json
            }
            json.advance_token(parser)

            if depth == 0 {
                return .None
            }
        }

    case .EOF:
        return .Invalid_Json

    case:
        json.advance_token(parser)
        return .None
    }
}

@(private)
issue_append :: proc(result: ^Result, selection: Selection, issue_error: Provider_Error) {
    assert(result != nil, "catalog issue append needs a result")
    assert(issue_error != .None, "a catalog issue carries a failure")

    issue := Issue {
        provider_id = wire.Provider_Id(strings.clone(selection.provider_id, result.allocator)),
        source_id   = strings.clone(selection.source_id, result.allocator),
        error       = issue_error,
    }
    append(&result.issues, issue)
}

@(private)
provider_normalize :: proc(
    out: ^Provider,
    selection: Selection,
    object: json.Object,
    allocator: mem.Allocator,
) -> (
    err: Normalize_Error,
) {
    assert(out != nil, "provider normalization needs output storage")
    assert(out.id == "" && out.models == nil, "provider normalization needs empty output storage")
    assert(allocator.procedure != nil, "provider normalization needs an allocator")
    out.models.allocator = allocator
    defer if err != .None {
        provider_destroy(out, allocator)
    }

    source_id, source_present, source_valid := json.read_string(object, "id", 64, false)
    name, name_present, name_valid := json.read_string(object, "name", PROVIDER_NAME_MAX_BYTES, false)
    npm, _, npm_valid := json.read_string(object, "npm", PACKAGE_MAX_BYTES, false)
    api, _, api_valid := json.read_string(object, "api", BASE_URL_MAX_BYTES, false)
    if !source_present ||
       !source_valid ||
       source_id != selection.source_id ||
       !name_present ||
       !name_valid ||
       !npm_valid ||
       !api_valid {
        return .Invalid
    }
    if len(npm) == 0 {
        npm = "@ai-sdk/openai-compatible"
    }

    endpoint, endpoint_err := endpoint_resolve(selection.source_id, npm, api, "")
    if endpoint_err != .None {
        return endpoint_err
    }

    env, env_err := credential_env_normalize(object, allocator)
    if env_err != .None {
        return env_err
    }
    out.credential_env = env

    models_value, models_present := object["models"]
    models, models_ok := models_value.(json.Object)
    if !models_present || !models_ok {
        return .Invalid
    }

    out.id = wire.Provider_Id(strings.clone(selection.provider_id, allocator))
    out.source_id = strings.clone(selection.source_id, allocator)
    out.name = strings.clone(name, allocator)
    out.endpoint = provider.Endpoint {
        base_url = strings.clone(endpoint.base_url, allocator),
        protocol = endpoint.protocol,
    }

    for model_key, value in models {
        model_object, model_ok := value.(json.Object)
        if !model_ok {
            return .Invalid
        }

        model: Model
        model_err := model_normalize(&model, out.id, model_key, model_object, out.endpoint, npm, allocator)
        switch model_err {
        case .None:
            for previous in out.models {
                if previous.info.id == model.info.id {
                    model_destroy(&model, allocator)
                    return .Invalid
                }
            }

            if len(out.models) >= wire.LIMITS.max_catalog_models {
                model_destroy(&model, allocator)
                return .Invalid
            }

            append(&out.models, model)

        case .Filtered, .Unsupported:
            continue

        case .Invalid:
            return .Invalid
        }
    }

    slice.sort_by(out.models[:], proc(a, b: Model) -> bool {return a.info.id < b.info.id})

    return .None
}

@(private)
model_normalize :: proc(
    out: ^Model,
    provider_id: wire.Provider_Id,
    source_key: string,
    object: json.Object,
    provider_endpoint: provider.Endpoint,
    provider_package: string,
    allocator: mem.Allocator,
) -> (
    err: Normalize_Error,
) {
    assert(out != nil, "model normalization needs output storage")
    assert(out.info.id == "", "model normalization needs empty output storage")
    assert(
        provider.endpoint_validate(provider_endpoint) == .None,
        "model normalization needs a validated provider endpoint",
    )
    defer if err != .None {
        model_destroy(out, allocator)
    }

    upstream_id, id_present, id_valid := json.read_string(object, "id", 128, false)
    name, name_present, name_valid := json.read_string(object, "name", 128, false)
    family, _, family_valid := json.read_string(object, "family", 128, true)
    tools, tools_present, tools_valid := json.read_bool(object, "tool_call")
    temperature, _, temperature_valid := json.read_bool(object, "temperature")
    if !id_present ||
       !id_valid ||
       source_key != upstream_id ||
       !name_present ||
       !name_valid ||
       !family_valid ||
       !tools_present ||
       !tools_valid ||
       !temperature_valid {
        return .Invalid
    }

    text_input, text_output, vision, modalities_valid := model_modalities(object)
    if !modalities_valid {
        return .Invalid
    }
    if !text_input || !text_output {
        return .Filtered
    }

    limit, _, limit_valid := json.read_object(object, "limit")
    context_window, context_present, context_valid := json.read_u64(limit, "context", 1, u64(wire.MAX_WIRE_INTEGER))
    max_output_tokens, output_present, output_valid := json.read_u64(limit, "output", 1, u64(wire.MAX_WIRE_INTEGER))
    if !limit_valid || !context_present || !context_valid || !output_present || !output_valid {
        return .Filtered
    }

    endpoint, npm, route_err := model_route(object, provider_endpoint, provider_package)
    if route_err != .None {
        return route_err
    }

    replay, interleaved_present, replay_err := reasoning_replay_normalize(object, npm)
    if replay_err != .None {
        return replay_err
    }

    reasoning, reasoning_err := reasoning_normalize(object, endpoint.protocol, npm, family, interleaved_present)
    if reasoning_err != .None {
        return reasoning_err
    }

    cost, cost_err := cost_normalize(object)
    if cost_err != .None {
        return cost_err
    }

    public_id := strings.concatenate({provider_id, "/", upstream_id}, allocator)
    out.info.id = wire.Model_Id(public_id)
    if len(out.info.id) > 128 {
        return .Filtered
    }

    out.info.name = strings.clone(name, allocator)
    out.info.provider = provider_id
    out.info.context_window = context_window
    out.info.max_output_tokens = max_output_tokens
    out.info.reasoning_levels = reasoning_levels_clone(reasoning, allocator)
    out.info.default_reasoning = strings.clone(default_reasoning_level(out.info.reasoning_levels), allocator)
    out.info.supports_vision = vision
    out.info.supports_tools = tools
    out.info.cost = cost
    out.upstream_id = strings.clone(upstream_id, allocator)
    out.endpoint = provider.Endpoint {
        base_url = strings.clone(endpoint.base_url, allocator),
        protocol = endpoint.protocol,
    }
    out.supports_temperature = temperature

    // Replay names an assistant-message field in the OpenAI-chat body, so it is recorded
    // only where a builder can act on it. `interleaved` still shapes the level set above.
    if endpoint.protocol == .Openai_Chat {
        out.reasoning_replay = replay
    }
    out.thinking_format = reasoning.format
    out.anthropic_adaptive = reasoning.adaptive
    out.reasoning_budget_min = reasoning.budget_min
    out.reasoning_budget_max = reasoning.budget_max
    out.max_tokens_field = max_tokens_field_resolve(npm, endpoint.protocol)

    if wire.model_info_validate(out.info) != .None {
        return .Filtered
    }

    return .None
}

@(private)
endpoint_resolve :: proc(
    source_id: string,
    npm: string,
    api: string,
    shape: string,
) -> (
    endpoint: provider.Endpoint,
    err: Normalize_Error,
) {
    protocol, protocol_ok := protocol_resolve(npm, shape)
    if !protocol_ok {
        return {}, .Unsupported
    }

    base_url := api
    if len(base_url) == 0 {
        switch {
        case npm == "@ai-sdk/openai" && source_id == "openai":
            base_url = OPENAI_BASE_URL

        case npm == "@ai-sdk/anthropic" && source_id == "anthropic":
            base_url = ANTHROPIC_BASE_URL

        case npm == "@ai-sdk/xai" && source_id == "xai":
            base_url = provider.XAI_API_BASE_URL

        case:
            return {}, .Invalid
        }
    }

    if strings.contains(base_url, "${") {
        return {}, .Unsupported
    }

    base_url = strings.trim_right(base_url, "/")
    endpoint = {
        base_url = base_url,
        protocol = protocol,
    }
    if provider.endpoint_validate(endpoint) != .None {
        return {}, .Invalid
    }

    return endpoint, .None
}

@(private)
protocol_resolve :: proc(npm: string, shape: string) -> (wire.Provider_Protocol, bool) {
    if len(shape) > 0 {
        switch npm {
        case "@ai-sdk/openai-compatible", "@ai-sdk/openai", "@ai-sdk/xai":
            switch shape {
            case "responses":
                return .Openai_Responses, true

            case "completions":
                return .Openai_Chat, true
            }
        }

        return {}, false
    }

    switch npm {
    case "@ai-sdk/openai-compatible", "@openrouter/ai-sdk-provider":
        return .Openai_Chat, true

    case "@ai-sdk/openai", "@ai-sdk/xai":
        return .Openai_Responses, true

    case "@ai-sdk/anthropic":
        return .Anthropic_Messages, true
    }

    return {}, false
}

@(private)
model_route :: proc(
    object: json.Object,
    provider_endpoint: provider.Endpoint,
    provider_package: string,
) -> (
    endpoint: provider.Endpoint,
    npm: string,
    err: Normalize_Error,
) {
    value, present := object["provider"]
    if !present {
        return provider_endpoint, provider_package, .None
    }

    route, route_ok := value.(json.Object)
    if !route_ok {
        return {}, "", .Invalid
    }

    if _, body_present := route["body"]; body_present {
        return {}, "", .Unsupported
    }
    if _, headers_present := route["headers"]; headers_present {
        return {}, "", .Unsupported
    }

    route_package, _, package_valid := json.read_string(route, "npm", PACKAGE_MAX_BYTES, false)
    route_api, _, api_valid := json.read_string(route, "api", BASE_URL_MAX_BYTES, false)
    shape, _, shape_valid := json.read_string(route, "shape", 32, false)
    if !package_valid || !api_valid || !shape_valid {
        return {}, "", .Invalid
    }

    if len(route_package) == 0 {
        route_package = provider_package
    }
    api := route_api if len(route_api) > 0 else provider_endpoint.base_url
    resolved, endpoint_err := endpoint_resolve("", route_package, api, shape)
    if endpoint_err != .None {
        return {}, "", endpoint_err
    }

    return resolved, route_package, .None
}

@(private)
credential_env_normalize :: proc(
    object: json.Object,
    allocator: mem.Allocator,
) -> (
    names: []string,
    err: Normalize_Error,
) {
    value, present := object["env"]
    array, array_ok := value.(json.Array)
    if !present || !array_ok || len(array) > 32 {
        return nil, .Invalid
    }

    names = make([]string, len(array), allocator)
    defer if err != .None {
        for name in names {
            delete(name, allocator)
        }
        delete(names, allocator)
        names = nil
    }

    for item, i in array {
        name, name_ok := item.(json.String)
        if !name_ok || !env_name_valid(name) {
            return names, .Invalid
        }

        for previous in array[:i] {
            previous_name, previous_ok := previous.(json.String)
            if !previous_ok || previous_name == name {
                return names, .Invalid
            }
        }

        names[i] = strings.clone(name, allocator)
    }

    return names, .None
}

@(private)
model_modalities :: proc(object: json.Object) -> (input, output, vision, valid: bool) {
    value, present := object["modalities"]
    if !present {
        return false, false, false, true
    }

    modalities, object_ok := value.(json.Object)
    if !object_ok {
        return false, false, false, false
    }

    input_value, input_present := modalities["input"]
    inputs, input_ok := input_value.(json.Array)
    output_value, output_present := modalities["output"]
    outputs, output_ok := output_value.(json.Array)
    if !input_present || !input_ok || !output_present || !output_ok {
        return false, false, false, false
    }

    for item in inputs {
        modality, modality_ok := item.(json.String)
        if !modality_ok {
            return false, false, false, false
        }

        input = input || modality == "text"
        vision = vision || modality == "image"
    }
    for item in outputs {
        modality, modality_ok := item.(json.String)
        if !modality_ok {
            return false, false, false, false
        }

        output = output || modality == "text"
    }

    return input, output, vision, true
}

@(private)
reasoning_replay_normalize :: proc(
    object: json.Object,
    npm: string,
) -> (
    replay: provider.Openai_Reasoning_Replay,
    present: bool,
    err: Normalize_Error,
) {
    value, found := object["interleaved"]
    if !found {
        return .None, false, .None
    }

    if npm == "@openrouter/ai-sdk-provider" {
        return .None, true, .None
    }

    #partial switch item in value {
    case json.Boolean:
        return .Reasoning_Content if bool(item) else .None, true, .None

    case json.Object:
        field, field_present, field_valid := json.read_string(item, "field", 32, false)
        if !field_present || !field_valid {
            return .None, true, .Invalid
        }

        switch field {
        case "reasoning_content":
            return .Reasoning_Content, true, .None

        case "reasoning_details":
            return .Reasoning_Details, true, .None
        }
    }

    return .None, true, .Invalid
}

@(private)
reasoning_normalize :: proc(
    object: json.Object,
    protocol: wire.Provider_Protocol,
    npm: string,
    family: string,
    interleaved_present: bool,
) -> (
    spec: Reasoning_Spec,
    err: Normalize_Error,
) {
    value, present := object["reasoning_options"]
    if !present {
        return spec, .None
    }

    options, options_ok := value.(json.Array)
    if !options_ok {
        return spec, .Invalid
    }
    if len(options) == 0 {
        return spec, .None
    }

    primary: json.Object
    primary_kind := Reasoning_Option_Kind.None
    has_toggle := false
    for item, i in options {
        option, option_ok := item.(json.Object)
        if !option_ok {
            return spec, .Invalid
        }

        kind, kind_err := reasoning_option_kind(option)
        if kind_err != .None {
            return spec, kind_err
        }
        has_toggle = has_toggle || kind == .Toggle

        if i == 0 {
            primary = option
            primary_kind = kind
        }

        if kind == .Effort && primary_kind != .Effort {
            primary = option
            primary_kind = .Effort
        }
    }

    switch protocol {
    case .Anthropic_Messages:
        switch primary_kind {
        case .Effort:
            reasoning_level_add(&spec, "off")
            effort_levels_add(&spec, primary) or_return

        case .Budget_Tokens:
            reasoning_level_add(&spec, "off")
            reasoning_level_add(&spec, "high")
            reasoning_level_add(&spec, "max")
            spec.budget_min, spec.budget_max = reasoning_budget(primary) or_return

        case .Toggle:
            spec.adaptive = true
            reasoning_level_add(&spec, "off")
            reasoning_level_add(&spec, "high")

        case .None:
        }

    case .Openai_Responses:
        if primary_kind == .Effort {
            effort_levels_add(&spec, primary) or_return
        }

    case .Openai_Chat:
        if primary_kind == .Effort {
            values, values_present := primary["values"]
            effort_values, values_ok := values.(json.Array)
            if !values_present || !values_ok {
                return spec, .Invalid
            }

            off_present := effort_values_contain_off(effort_values) or_return
            if (interleaved_present || has_toggle) && !off_present {
                reasoning_level_add(&spec, "off")
            }
            effort_levels_add(&spec, primary) or_return

            spec.format = .Openrouter if npm == "@openrouter/ai-sdk-provider" else .Deepseek if has_toggle else .Openai
        } else if primary_kind == .Toggle {
            reasoning_level_add(&spec, "off")
            reasoning_level_add(&spec, "high")
            spec.format = .Qwen if strings.has_prefix(family, "qwen") else .Zai
        }
    }

    return spec, .None
}

@(private)
reasoning_option_kind :: proc(object: json.Object) -> (Reasoning_Option_Kind, Normalize_Error) {
    kind, present, valid := json.read_string(object, "type", 32, false)
    if !present || !valid {
        return .None, .Invalid
    }

    switch kind {
    case "effort":
        return .Effort, .None

    case "budget_tokens":
        return .Budget_Tokens, .None

    case "toggle":
        return .Toggle, .None
    }

    return .None, .Invalid
}

@(private)
effort_levels_add :: proc(spec: ^Reasoning_Spec, option: json.Object) -> Normalize_Error {
    assert(spec != nil, "effort normalization needs a reasoning spec")

    value, present := option["values"]
    values, values_ok := value.(json.Array)
    if !present || !values_ok {
        return .Invalid
    }

    for item in values {
        level, known, valid := reasoning_level(item)
        if !valid {
            return .Invalid
        }
        if known {
            reasoning_level_add(spec, level)
        }
    }

    return .None
}

@(private)
effort_values_contain_off :: proc(values: json.Array) -> (bool, Normalize_Error) {
    for value in values {
        level, known, valid := reasoning_level(value)
        if !valid {
            return false, .Invalid
        }
        if known && level == "off" {
            return true, .None
        }
    }

    return false, .None
}

@(private)
reasoning_level :: proc(value: json.Value) -> (level: string, known, valid: bool) {
    if _, null_ok := value.(json.Null); null_ok {
        return "off", true, true
    }

    token, string_ok := value.(json.String)
    if !string_ok {
        return "", false, false
    }

    switch token {
    case "none", "off":
        return "off", true, true

    case "default":
        return "high", true, true

    case "minimal", "low", "medium", "high", "xhigh", "max":
        return token, true, true
    }

    return "", false, true
}

@(private)
reasoning_level_add :: proc(spec: ^Reasoning_Spec, level: string) {
    assert(spec != nil, "reasoning level append needs a spec")
    assert(len(level) > 0 && len(level) <= 32, "a canonical reasoning level fits the wire")

    for previous in spec.levels[:spec.level_count] {
        if previous == level {
            return
        }
    }

    assert(spec.level_count < len(spec.levels), "the closed reasoning level set fits its bound")
    spec.levels[spec.level_count] = level
    spec.level_count += 1
}

@(private)
reasoning_budget :: proc(object: json.Object) -> (minimum: Maybe(i64), maximum: Maybe(u64), err: Normalize_Error) {
    if value, present := object["min"]; present {
        parsed, valid := json.integer_i64(value)
        if !valid || parsed < -1 {
            return nil, nil, .Invalid
        }
        minimum = parsed
    }

    if value, present := object["max"]; present {
        parsed, valid := json.integer_i64(value)
        if !valid || parsed < 0 {
            return nil, nil, .Invalid
        }
        maximum = u64(parsed)
    }

    if min_value, min_present := minimum.?; min_present {
        if max_value, max_present := maximum.?; max_present && min_value > i64(max_value) {
            return nil, nil, .Invalid
        }
    }

    return minimum, maximum, .None
}

@(private)
reasoning_levels_clone :: proc(spec: Reasoning_Spec, allocator: mem.Allocator) -> (levels: []string) {
    levels = make([]string, spec.level_count, allocator)

    for i in 0 ..< spec.level_count {
        levels[i] = strings.clone(spec.levels[i], allocator)
    }

    return levels
}

// Prefer "medium", otherwise the middle level, and no default for an empty set. Imported
// and custom models share this one rule so their defaults cannot diverge.
default_reasoning_level :: proc(levels: []string) -> string {
    if len(levels) == 0 {
        return ""
    }

    for level in levels {
        if level == "medium" {
            return level
        }
    }

    return levels[len(levels) / 2]
}

@(private)
cost_normalize :: proc(object: json.Object) -> (cost: wire.Model_Cost, err: Normalize_Error) {
    value, present := object["cost"]
    if !present {
        return {}, .None
    }

    cost_object, object_ok := value.(json.Object)
    if !object_ok {
        return {}, .Invalid
    }

    input, input_present, input_valid := json.read_f64_nonneg(cost_object, "input")
    output, output_present, output_valid := json.read_f64_nonneg(cost_object, "output")
    cache_read, _, cache_read_valid := json.read_f64_nonneg(cost_object, "cache_read")
    cache_write, _, cache_write_valid := json.read_f64_nonneg(cost_object, "cache_write")
    if !input_present || !input_valid || !output_present || !output_valid || !cache_read_valid || !cache_write_valid {
        return {}, .Invalid
    }

    return {input = input, output = output, cache_read = cache_read, cache_write = cache_write}, .None
}
