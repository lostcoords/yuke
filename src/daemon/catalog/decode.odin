package catalog

import "base:runtime"
import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import provider "src:provider"
import wire "src:wire"

OPENAI_BASE_URL :: "https://api.openai.com/v1"
ANTHROPIC_BASE_URL :: "https://api.anthropic.com/v1"

Normalize_Error :: enum {
    None,
    Filtered,
    Unsupported,
    Invalid,
    Out_Of_Memory,
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
    format:      Reasoning_Format,
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
    if virtual.arena_init_growing(&scratch) != nil {
        return result, .Out_Of_Memory
    }
    defer virtual.arena_destroy(&scratch)
    sa := virtual.arena_allocator(&scratch)

    selected, selected_err := make([]json.Object, len(selections), sa)
    if selected_err != nil {
        return result, .Out_Of_Memory
    }
    found, found_err := make([]bool, len(selections), sa)
    if found_err != nil {
        return result, .Out_Of_Memory
    }

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
            return result, .Out_Of_Memory if parse_err == .Out_Of_Memory else .Invalid_Json
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
            issue_append(&result, selection, .Missing) or_return
            continue
        }

        if selected[i] == nil {
            issue_append(&result, selection, .Invalid) or_return
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

            if _, append_err := append(&result.providers, item); append_err != nil {
                provider_destroy(&item, allocator)
                return result, .Out_Of_Memory
            }

        case .Unsupported:
            issue_append(&result, selection, .Unsupported) or_return

        case .Invalid, .Filtered:
            issue_append(&result, selection, .Invalid) or_return

        case .Out_Of_Memory:
            return result, .Out_Of_Memory
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
        return "", .Out_Of_Memory if key_err == .Out_Of_Memory else .Invalid_Json
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
issue_append :: proc(result: ^Result, selection: Selection, issue_error: Provider_Error) -> Error {
    assert(result != nil, "catalog issue append needs a result")
    assert(issue_error != .None, "a catalog issue carries a failure")

    provider_id, provider_err := strings.clone(selection.provider_id, result.allocator)
    if provider_err != nil {
        return .Out_Of_Memory
    }

    source_id, source_err := strings.clone(selection.source_id, result.allocator)
    if source_err != nil {
        delete(provider_id, result.allocator)
        return .Out_Of_Memory
    }

    issue := Issue {
        provider_id = wire.Provider_Id(provider_id),
        source_id   = source_id,
        error       = issue_error,
    }
    if _, append_err := append(&result.issues, issue); append_err != nil {
        delete(provider_id, result.allocator)
        delete(source_id, result.allocator)
        return .Out_Of_Memory
    }

    return .None
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

    source_id, source_present, source_valid := object_string(object, "id", 64, false)
    name, name_present, name_valid := object_string(object, "name", PROVIDER_NAME_MAX_BYTES, false)
    npm, _, npm_valid := object_string(object, "npm", PACKAGE_MAX_BYTES, false)
    api, _, api_valid := object_string(object, "api", BASE_URL_MAX_BYTES, false)
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

    out.id = wire.Provider_Id(clone_owned(selection.provider_id, allocator) or_return)
    out.source_id = clone_owned(selection.source_id, allocator) or_return
    out.name = clone_owned(name, allocator) or_return
    out.endpoint = provider.Endpoint {
        base_url = clone_owned(endpoint.base_url, allocator) or_return,
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

            if _, append_err := append(&out.models, model); append_err != nil {
                model_destroy(&model, allocator)
                return .Out_Of_Memory
            }

        case .Filtered, .Unsupported:
            continue

        case .Invalid:
            return .Invalid

        case .Out_Of_Memory:
            return .Out_Of_Memory
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

    upstream_id, id_present, id_valid := object_string(object, "id", 128, false)
    name, name_present, name_valid := object_string(object, "name", 128, false)
    family, _, family_valid := object_string(object, "family", 128, true)
    tools, tools_present, tools_valid := object_bool(object, "tool_call")
    temperature, _, temperature_valid := object_bool(object, "temperature")
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

    context_window, context_present, context_valid := object_positive_u64(object, "limit", "context")
    max_output_tokens, output_present, output_valid := object_positive_u64(object, "limit", "output")
    if !context_present || !context_valid || !output_present || !output_valid {
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

    public_id, public_err := strings.concatenate({provider_id, "/", upstream_id}, allocator)
    if public_err != nil {
        return .Out_Of_Memory
    }
    out.info.id = wire.Model_Id(public_id)
    if len(out.info.id) > 128 {
        return .Filtered
    }

    out.info.name = clone_owned(name, allocator) or_return
    out.info.provider = provider_id
    out.info.context_window = context_window
    out.info.max_output_tokens = max_output_tokens
    out.info.reasoning_levels = reasoning_levels_clone(reasoning, allocator) or_return
    out.info.default_reasoning = reasoning_default_clone(out.info.reasoning_levels, allocator) or_return
    out.info.supports_vision = vision
    out.info.supports_tools = tools
    out.info.cost = cost
    out.upstream_id = clone_owned(upstream_id, allocator) or_return
    out.endpoint = provider.Endpoint {
        base_url = clone_owned(endpoint.base_url, allocator) or_return,
        protocol = endpoint.protocol,
    }
    out.temperature = temperature
    out.reasoning_replay = replay
    out.reasoning_format = reasoning.format
    out.reasoning_budget_min = reasoning.budget_min
    out.reasoning_budget_max = reasoning.budget_max

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

    route_package, _, package_valid := object_string(route, "npm", PACKAGE_MAX_BYTES, false)
    route_api, _, api_valid := object_string(route, "api", BASE_URL_MAX_BYTES, false)
    shape, _, shape_valid := object_string(route, "shape", 32, false)
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

    allocation_err: runtime.Allocator_Error
    names, allocation_err = make([]string, len(array), allocator)
    if allocation_err != nil {
        return nil, .Out_Of_Memory
    }
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

        names[i] = clone_owned(name, allocator) or_return
    }

    return names, .None
}

@(private)
env_name_valid :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > 128 {
        return false
    }

    for byte, i in transmute([]byte)name {
        if i == 0 {
            if byte != '_' && !(byte >= 'a' && byte <= 'z') && !(byte >= 'A' && byte <= 'Z') {
                return false
            }
        } else if byte != '_' &&
           !(byte >= 'a' && byte <= 'z') &&
           !(byte >= 'A' && byte <= 'Z') &&
           !(byte >= '0' && byte <= '9') {
            return false
        }
    }

    return true
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
    replay: Reasoning_Replay,
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
        field, field_present, field_valid := object_string(item, "field", 32, false)
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
        if primary_kind == .Toggle {
            spec.format = .Anthropic_Adaptive
        }

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

            spec.format =
                .Openrouter_Effort if npm == "@openrouter/ai-sdk-provider" else .Openai_Effort_Toggle_Off if has_toggle else .Native
        } else if primary_kind == .Toggle {
            reasoning_level_add(&spec, "off")
            reasoning_level_add(&spec, "high")
            spec.format = .Qwen_Thinking if strings.has_prefix(family, "qwen") else .Zai_Toggle
        }
    }

    return spec, .None
}

@(private)
reasoning_option_kind :: proc(object: json.Object) -> (Reasoning_Option_Kind, Normalize_Error) {
    kind, present, valid := object_string(object, "type", 32, false)
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
        parsed, valid := json_integer_i64(value)
        if !valid || parsed < -1 {
            return nil, nil, .Invalid
        }
        minimum = parsed
    }

    if value, present := object["max"]; present {
        parsed, valid := json_integer_i64(value)
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
reasoning_levels_clone :: proc(
    spec: Reasoning_Spec,
    allocator: mem.Allocator,
) -> (
    levels: []string,
    err: Normalize_Error,
) {
    allocation_err: runtime.Allocator_Error
    levels, allocation_err = make([]string, spec.level_count, allocator)
    if allocation_err != nil {
        return nil, .Out_Of_Memory
    }
    defer if err != .None {
        for level in levels {
            delete(level, allocator)
        }
        delete(levels, allocator)
        levels = nil
    }

    for i in 0 ..< spec.level_count {
        levels[i] = clone_owned(spec.levels[i], allocator) or_return
    }

    return levels, .None
}

@(private)
reasoning_default_clone :: proc(levels: []string, allocator: mem.Allocator) -> (string, Normalize_Error) {
    if len(levels) == 0 {
        return clone_owned("", allocator)
    }

    selected := levels[len(levels) / 2]
    for level in levels {
        if level == "medium" {
            selected = level
            break
        }
    }

    return clone_owned(selected, allocator)
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

    input, input_present, input_valid := object_nonnegative_f64(cost_object, "input")
    output, output_present, output_valid := object_nonnegative_f64(cost_object, "output")
    cache_read, _, cache_read_valid := object_nonnegative_f64(cost_object, "cache_read")
    cache_write, _, cache_write_valid := object_nonnegative_f64(cost_object, "cache_write")
    if !input_present || !input_valid || !output_present || !output_valid || !cache_read_valid || !cache_write_valid {
        return {}, .Invalid
    }

    return {input = input, output = output, cache_read = cache_read, cache_write = cache_write}, .None
}

@(private)
object_string :: proc(
    object: json.Object,
    name: string,
    max_bytes: int,
    allow_empty: bool,
) -> (
    value: string,
    present: bool,
    valid: bool,
) {
    assert(max_bytes > 0, "an external string field needs a positive bound")

    member, found := object[name]
    if !found {
        return "", false, true
    }

    text, ok := member.(json.String)
    if !ok || (!allow_empty && len(text) == 0) || len(text) > max_bytes || !utf8.valid_string(text) {
        return "", true, false
    }

    return text, true, true
}

@(private)
object_bool :: proc(object: json.Object, name: string) -> (value: bool, present, valid: bool) {
    member, found := object[name]
    if !found {
        return false, false, true
    }

    boolean, ok := member.(json.Boolean)
    if !ok {
        return false, true, false
    }

    return bool(boolean), true, true
}

@(private)
object_positive_u64 :: proc(
    object: json.Object,
    object_name, field_name: string,
) -> (
    value: u64,
    present, valid: bool,
) {
    member, found := object[object_name]
    if !found {
        return 0, false, true
    }

    nested, object_ok := member.(json.Object)
    if !object_ok {
        return 0, true, false
    }

    number, field_present := nested[field_name]
    if !field_present {
        return 0, false, true
    }

    parsed, parsed_ok := json_integer_i64(number)
    if !parsed_ok || parsed <= 0 || parsed > wire.MAX_WIRE_INTEGER {
        return 0, true, false
    }

    return u64(parsed), true, true
}

@(private)
object_nonnegative_f64 :: proc(object: json.Object, name: string) -> (value: f64, present, valid: bool) {
    member, found := object[name]
    if !found {
        return 0, false, true
    }

    #partial switch number in member {
    case json.Integer:
        value = f64(number)

    case json.Float:
        value = f64(number)

    case:
        return 0, true, false
    }

    if value < 0 || math.is_nan(value) || math.is_inf(value) {
        return 0, true, false
    }

    return value, true, true
}

@(private)
json_integer_i64 :: proc(value: json.Value) -> (i64, bool) {
    #partial switch number in value {
    case json.Integer:
        return i64(number), true

    case json.Float:
        if !math.is_nan(number) &&
           !math.is_inf(number) &&
           math.floor(number) == number &&
           number >= f64(min(i64)) &&
           number <= f64(max(i64)) {
            return i64(number), true
        }
    }

    return 0, false
}

@(private)
clone_owned :: proc(value: string, allocator: mem.Allocator) -> (string, Normalize_Error) {
    owned, allocation_err := strings.clone(value, allocator)
    if allocation_err != nil {
        return "", .Out_Of_Memory
    }

    return owned, .None
}
