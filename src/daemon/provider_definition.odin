package daemon

import "base:runtime"
import "core:c"
import "core:encoding/json"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

import qjs "libs:bindings/quickjs"
import js "src:js"
import provider "src:provider"
import "src:secret"
import wire "src:wire"

PROVIDER_DEFINITIONS_MAX_BYTES :: 8 * mem.Megabyte
PROVIDER_DEFINITIONS_MAX :: 256
PROVIDER_CREDENTIAL_ENV_MAX :: 32
PROVIDER_CREDENTIAL_ENV_NAME_MAX_BYTES :: 128
PROVIDER_BASE_URL_MAX_BYTES :: 4096
JAVASCRIPT_MAX_EXACT_INTEGER :: u64(9_007_199_254_740_991)

Provider_Capture :: struct {
    id:         string,
    definition: string,
}

Provider_Registry :: struct {
    captures:          [dynamic]Provider_Capture,
    capture_bytes:     int,
    capture_oom:       bool,
    registration_open: bool,
    definitions:       []Provider_Definition,
}

// One JavaScript-authored model. All strings and slices are daemon-owned.
Model_Definition :: struct {
    id:                wire.Model_Id,
    upstream_id:       string,
    name:              string,
    context_window:    u64,
    max_output_tokens: u64,
    reasoning_levels:  []string,
    default_reasoning: string,
    supports_vision:   bool,
    supports_tools:    bool,
    cost:              wire.Model_Cost,
}

// One JavaScript-authored provider and its complete model overrides. Owned by the daemon.
Provider_Definition :: struct {
    id:             wire.Provider_Id,
    name:           string,
    base_url:       string,
    protocol:       wire.Provider_Protocol,
    has_endpoint:   bool,
    credential_env: []string,
    models_dev:     string,
    models:         []Model_Definition,
}

Provider_Definition_Error :: enum {
    None,
    Invalid,
    Out_Of_Memory,
}

// Capture `defineProvider(id, definition)` during entry evaluation. Content validation waits
// until the entry and its top-level await settle, so call order cannot affect the registry.
define_provider :: proc "c" (ctx: ^qjs.Context, this: qjs.Value, argc: c.int, argv: [^]qjs.Value) -> qjs.Value {
    context = runtime.default_context()

    d := (^Daemon)(js.user_of(ctx))
    if d == nil {
        return qjs.throw_type_error(ctx, "defineProvider has no daemon")
    }

    if !d.providers.registration_open {
        return qjs.throw_type_error(ctx, "defineProvider is only available during entry evaluation")
    }

    if argc < 2 || !qjs.is_string(argv[0]) || !qjs.is_object(argv[1]) {
        return qjs.throw_type_error(ctx, "defineProvider expects an id string and definition object")
    }

    if len(d.providers.captures) >= PROVIDER_DEFINITIONS_MAX {
        return qjs.throw_type_error(ctx, "too many provider definitions")
    }

    assert(
        d.providers.capture_bytes >= 0 && d.providers.capture_bytes <= PROVIDER_DEFINITIONS_MAX_BYTES,
        "provider capture accounting is invalid",
    )

    id, id_ok := qjs.to_string(ctx, argv[0])
    if !id_ok {
        return qjs.throw_type_error(ctx, "defineProvider could not read its id")
    }
    defer qjs.free_string(ctx, id)

    encoded := qjs.json_stringify(ctx, argv[1])
    if qjs.is_exception(encoded) {
        return encoded
    }
    defer qjs.free_value(ctx, encoded)

    if !qjs.is_string(encoded) {
        return qjs.throw_type_error(ctx, "defineProvider could not serialize its definition")
    }

    text, text_ok := qjs.to_string(ctx, encoded)
    if !text_ok {
        return qjs.throw_type_error(ctx, "defineProvider could not read its definition")
    }
    defer qjs.free_string(ctx, text)

    room := PROVIDER_DEFINITIONS_MAX_BYTES - d.providers.capture_bytes
    if len(id) > room || len(text) > room - len(id) {
        return qjs.throw_type_error(ctx, "provider definitions are too large")
    }

    owned_id, id_err := strings.clone(id, d.allocator)
    if id_err != nil {
        d.providers.capture_oom = true

        return qjs.throw_type_error(ctx, "out of memory")
    }

    owned_text, text_err := strings.clone(text, d.allocator)
    if text_err != nil {
        delete(owned_id, d.allocator)
        d.providers.capture_oom = true

        return qjs.throw_type_error(ctx, "out of memory")
    }

    capture := Provider_Capture {
        id         = owned_id,
        definition = owned_text,
    }
    if _, append_err := append(&d.providers.captures, capture); append_err != nil {
        delete(owned_id, d.allocator)
        secret.string_destroy(&owned_text, d.allocator)
        d.providers.capture_oom = true

        return qjs.throw_type_error(ctx, "out of memory")
    }

    d.providers.capture_bytes += len(owned_id) + len(owned_text)
    assert(d.providers.capture_bytes <= PROVIDER_DEFINITIONS_MAX_BYTES, "provider captures escaped their bound")

    return qjs.dup_value(ctx, argv[1])
}

// Decode all captured calls after entry evaluation. On success the captures are gone and the
// daemon owns only typed records; on failure both the parse scratch and captures are wiped.
provider_definitions_finalize :: proc(d: ^Daemon) -> Error {
    assert(d != nil, "provider finalization needs daemon state")
    assert(!d.providers.registration_open, "provider finalization during registration")
    assert(d.providers.definitions == nil, "provider definitions finalized twice")
    defer provider_captures_destroy(d)

    if len(d.providers.captures) == 0 {
        return .None
    }

    for capture, i in d.providers.captures {
        for previous in d.providers.captures[:i] {
            if previous.id == capture.id {
                return .Invalid_Options
            }
        }
    }

    definitions, definitions_err := make([]Provider_Definition, len(d.providers.captures), d.allocator)
    if definitions_err != nil {
        return .Out_Of_Memory
    }

    parse_scratch: virtual.Arena
    if virtual.arena_init_growing(&parse_scratch) != nil {
        delete(definitions, d.allocator)
        return .Out_Of_Memory
    }
    defer virtual.arena_destroy(&parse_scratch)

    model_count := 0
    for capture, i in d.providers.captures {
        temp := virtual.arena_temp_begin(&parse_scratch)
        definition_err := provider_definition_decode(
            &definitions[i],
            capture.id,
            capture.definition,
            virtual.arena_allocator(&parse_scratch),
            d.allocator,
        )
        secret.arena_temp_destroy(temp)

        if definition_err != .None {
            provider_definition_slice_destroy(definitions, d.allocator)

            return .Out_Of_Memory if definition_err == .Out_Of_Memory else .Invalid_Options
        }

        if len(definitions[i].models) > wire.LIMITS.max_catalog_models - model_count {
            provider_definition_slice_destroy(definitions, d.allocator)

            return .Invalid_Options
        }
        model_count += len(definitions[i].models)
    }

    d.providers.definitions = definitions

    return .None
}

provider_definition_decode :: proc(
    out: ^Provider_Definition,
    id: string,
    text: string,
    scratch_allocator: runtime.Allocator,
    allocator: mem.Allocator,
) -> (
    err: Provider_Definition_Error,
) {
    assert(out != nil, "provider decode needs output storage")
    assert(out.id == "" && out.models == nil, "provider decode needs empty output storage")
    assert(scratch_allocator.procedure != nil, "provider decode needs scratch")
    assert(allocator.procedure != nil, "provider decode needs owned storage")
    defer if err != .None {
        provider_definition_destroy(out, allocator)
    }

    if wire.provider_id_validate(id) != .None {
        return .Invalid
    }

    parser := json.make_parser_from_string(text, .JSON, false, scratch_allocator)
    value, parse_err := json.parse_value(&parser)
    if parse_err != nil {
        return .Out_Of_Memory if parse_err == .Out_Of_Memory else .Invalid
    }

    object, object_ok := value.(json.Object)
    if !object_ok || parser.curr_token.kind != .EOF || !provider_fields_valid(object) {
        return .Invalid
    }

    name, name_present, name_valid := provider_json_string(object, "name", 128, false)
    base_url, base_present, base_valid := provider_json_string(object, "baseUrl", PROVIDER_BASE_URL_MAX_BYTES, false)
    protocol_name, protocol_present, protocol_valid := provider_json_string(object, "protocol", 32, false)
    models_dev, models_dev_present, models_dev_valid := provider_json_string(object, "modelsDev", 64, false)
    if !name_valid || !base_valid || !protocol_valid || !models_dev_valid {
        return .Invalid
    }

    if base_present != protocol_present || (!base_present && !models_dev_present) {
        return .Invalid
    }

    protocol: wire.Provider_Protocol
    if protocol_present {
        protocol_ok: bool
        protocol, protocol_ok = provider_protocol_from_script(protocol_name)
        if !protocol_ok || provider.endpoint_validate({base_url = base_url, protocol = protocol}) != .None {
            return .Invalid
        }
    }

    if models_dev_present && wire.provider_id_validate(models_dev) != .None {
        return .Invalid
    }

    credential_env, credential_err := provider_credential_env_decode(object, allocator)
    if credential_err != .None {
        return credential_err
    }
    out.credential_env = credential_env

    models, models_err := provider_models_decode(object, id, allocator)
    if models_err != .None {
        return models_err
    }
    out.models = models

    out.id = provider_string_clone(id, allocator) or_return
    if name_present {
        out.name = provider_string_clone(name, allocator) or_return
    }
    if base_present {
        out.base_url = provider_string_clone(base_url, allocator) or_return
    }
    if models_dev_present {
        out.models_dev = provider_string_clone(models_dev, allocator) or_return
    }
    out.protocol = protocol
    out.has_endpoint = base_present

    return .None
}

provider_models_decode :: proc(
    object: json.Object,
    provider_id: string,
    allocator: mem.Allocator,
) -> (
    models: []Model_Definition,
    err: Provider_Definition_Error,
) {
    value, present := object["models"]
    if !present {
        return nil, .None
    }

    array, array_ok := value.(json.Array)
    if !array_ok || len(array) > wire.LIMITS.max_catalog_models {
        return nil, .Invalid
    }

    allocation_err: runtime.Allocator_Error
    models, allocation_err = make([]Model_Definition, len(array), allocator)
    if allocation_err != nil {
        return nil, .Out_Of_Memory
    }
    defer if err != .None {
        model_definition_slice_destroy(models, allocator)
        models = nil
    }

    for item, i in array {
        model, model_ok := item.(json.Object)
        if !model_ok {
            return models, .Invalid
        }

        if model_err := model_definition_decode(&models[i], provider_id, model, allocator); model_err != .None {
            return models, model_err
        }

        for previous in models[:i] {
            if previous.id == models[i].id {
                return models, .Invalid
            }
        }
    }

    return models, .None
}

model_definition_decode :: proc(
    out: ^Model_Definition,
    provider_id: string,
    object: json.Object,
    allocator: mem.Allocator,
) -> (
    err: Provider_Definition_Error,
) {
    assert(out != nil, "model decode needs output storage")
    assert(out.id == "" && out.reasoning_levels == nil, "model decode needs empty output storage")
    defer if err != .None {
        model_definition_destroy(out, allocator)
    }

    if !model_fields_valid(object) {
        return .Invalid
    }

    local_id, id_present, id_valid := provider_json_string(object, "id", 128, false)
    upstream_id, upstream_present, upstream_valid := provider_json_string(object, "upstreamId", 128, false)
    name, name_present, name_valid := provider_json_string(object, "name", 128, false)
    default_reasoning, default_present, default_valid := provider_json_string(object, "defaultReasoning", 32, true)
    if !id_present ||
       !id_valid ||
       !upstream_present ||
       !upstream_valid ||
       !name_present ||
       !name_valid ||
       !default_present ||
       !default_valid {
        return .Invalid
    }

    if len(provider_id) + 1 + len(local_id) > 128 {
        return .Invalid
    }

    context_window, context_present, context_valid := provider_json_positive_u64(object, "contextWindow")
    max_output_tokens, output_present, output_valid := provider_json_positive_u64(object, "maxOutputTokens")
    supports_vision, vision_present, vision_valid := provider_json_bool(object, "supportsVision")
    supports_tools, tools_present, tools_valid := provider_json_bool(object, "supportsTools")
    if !context_present ||
       !context_valid ||
       !output_present ||
       !output_valid ||
       !vision_present ||
       !vision_valid ||
       !tools_present ||
       !tools_valid {
        return .Invalid
    }

    reasoning_levels, reasoning_err := provider_reasoning_levels_decode(object, default_reasoning, allocator)
    if reasoning_err != .None {
        return reasoning_err
    }
    out.reasoning_levels = reasoning_levels

    cost, cost_err := provider_cost_decode(object)
    if cost_err != .None {
        return cost_err
    }

    out.id = provider_string_concatenate({provider_id, "/", local_id}, allocator) or_return
    out.upstream_id = provider_string_clone(upstream_id, allocator) or_return
    out.name = provider_string_clone(name, allocator) or_return
    out.default_reasoning = provider_string_clone(default_reasoning, allocator) or_return
    out.context_window = context_window
    out.max_output_tokens = max_output_tokens
    out.supports_vision = supports_vision
    out.supports_tools = supports_tools
    out.cost = cost

    projected := wire.Model_Info {
        id                = out.id,
        provider          = provider_id,
        name              = out.name,
        context_window    = out.context_window,
        max_output_tokens = out.max_output_tokens,
        reasoning_levels  = out.reasoning_levels,
        default_reasoning = out.default_reasoning,
        supports_vision   = out.supports_vision,
        supports_tools    = out.supports_tools,
        cost              = out.cost,
    }
    if wire.model_info_validate(projected) != .None {
        return .Invalid
    }

    return .None
}

provider_reasoning_levels_decode :: proc(
    object: json.Object,
    default_reasoning: string,
    allocator: mem.Allocator,
) -> (
    levels: []string,
    err: Provider_Definition_Error,
) {
    value, present := object["reasoningLevels"]
    if !present {
        return nil, .Invalid
    }

    array, array_ok := value.(json.Array)
    if !array_ok || len(array) > wire.LIMITS.max_reasoning_levels {
        return nil, .Invalid
    }

    allocation_err: runtime.Allocator_Error
    levels, allocation_err = make([]string, len(array), allocator)
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

    default_found := false
    for item, i in array {
        level, level_ok := item.(json.String)
        if !level_ok || len(level) == 0 || len(level) > 32 || !utf8.valid_string(level) {
            return levels, .Invalid
        }

        for previous in array[:i] {
            previous_level := previous.(json.String)
            if previous_level == level {
                return levels, .Invalid
            }
        }

        owned_level, clone_err := provider_string_clone(level, allocator)
        if clone_err != .None {
            return levels, clone_err
        }
        levels[i] = owned_level
        default_found = default_found || level == default_reasoning
    }

    if (len(levels) == 0 && default_reasoning != "") || (len(levels) > 0 && !default_found) {
        return levels, .Invalid
    }

    return levels, .None
}

provider_cost_decode :: proc(object: json.Object) -> (cost: wire.Model_Cost, err: Provider_Definition_Error) {
    value, present := object["cost"]
    if !present {
        return {}, .Invalid
    }

    cost_object, object_ok := value.(json.Object)
    if !object_ok || !provider_cost_fields_valid(cost_object) {
        return {}, .Invalid
    }

    input, input_present, input_valid := provider_json_nonnegative_f64(cost_object, "input")
    output, output_present, output_valid := provider_json_nonnegative_f64(cost_object, "output")
    cache_read, read_present, read_valid := provider_json_nonnegative_f64(cost_object, "cacheRead")
    cache_write, write_present, write_valid := provider_json_nonnegative_f64(cost_object, "cacheWrite")
    if !input_present ||
       !input_valid ||
       !output_present ||
       !output_valid ||
       !read_present ||
       !read_valid ||
       !write_present ||
       !write_valid {
        return {}, .Invalid
    }

    return {input = input, output = output, cache_read = cache_read, cache_write = cache_write}, .None
}

provider_credential_env_decode :: proc(
    object: json.Object,
    allocator: mem.Allocator,
) -> (
    names: []string,
    err: Provider_Definition_Error,
) {
    value, present := object["credentialEnv"]
    if !present {
        return nil, .None
    }

    array, array_ok := value.(json.Array)
    if !array_ok || len(array) > PROVIDER_CREDENTIAL_ENV_MAX {
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
        if !name_ok || !provider_env_name_valid(name) {
            return names, .Invalid
        }

        for previous in array[:i] {
            previous_name := previous.(json.String)
            if previous_name == name {
                return names, .Invalid
            }
        }

        owned_name, clone_err := provider_string_clone(name, allocator)
        if clone_err != .None {
            return names, clone_err
        }
        names[i] = owned_name
    }

    return names, .None
}

provider_json_string :: proc(
    object: json.Object,
    name: string,
    max_bytes: int,
    allow_empty: bool,
) -> (
    value: string,
    present: bool,
    valid: bool,
) {
    assert(max_bytes > 0, "a string member needs a positive bound")

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

provider_json_positive_u64 :: proc(object: json.Object, name: string) -> (value: u64, present, valid: bool) {
    member, found := object[name]
    if !found {
        return 0, false, true
    }

    #partial switch number in member {
    case json.Integer:
        if number > 0 && u64(number) <= JAVASCRIPT_MAX_EXACT_INTEGER {
            return u64(number), true, true
        }

    case json.Float:
        if number > 0 && number <= f64(JAVASCRIPT_MAX_EXACT_INTEGER) && math.floor(number) == number {
            return u64(number), true, true
        }
    }

    return 0, true, false
}

provider_json_nonnegative_f64 :: proc(object: json.Object, name: string) -> (value: f64, present, valid: bool) {
    member, found := object[name]
    if !found {
        return 0, false, true
    }

    number_value: f64
    #partial switch number in member {
    case json.Integer:
        number_value = f64(number)

    case json.Float:
        number_value = number

    case:
        return 0, true, false
    }

    if number_value < 0 || math.is_nan(number_value) || math.is_inf(number_value) {
        return 0, true, false
    }

    return number_value, true, true
}

provider_json_bool :: proc(object: json.Object, name: string) -> (value: bool, present, valid: bool) {
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

provider_fields_valid :: proc(object: json.Object) -> bool {
    for name in object {
        switch name {
        case "name", "baseUrl", "protocol", "credentialEnv", "modelsDev", "models":
        case:
            return false
        }
    }

    return true
}

model_fields_valid :: proc(object: json.Object) -> bool {
    for name in object {
        switch name {
        case "id",
             "upstreamId",
             "name",
             "contextWindow",
             "maxOutputTokens",
             "reasoningLevels",
             "defaultReasoning",
             "supportsVision",
             "supportsTools",
             "cost":
        case:
            return false
        }
    }

    return true
}

provider_cost_fields_valid :: proc(object: json.Object) -> bool {
    if len(object) != 4 {
        return false
    }

    for name in object {
        switch name {
        case "input", "output", "cacheRead", "cacheWrite":
        case:
            return false
        }
    }

    return true
}

provider_protocol_from_script :: proc(name: string) -> (wire.Provider_Protocol, bool) {
    switch name {
    case "anthropic-messages":
        return .Anthropic_Messages, true

    case "openai-chat":
        return .Openai_Chat, true

    case "openai-responses":
        return .Openai_Responses, true
    }

    return {}, false
}

provider_env_name_valid :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > PROVIDER_CREDENTIAL_ENV_NAME_MAX_BYTES {
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

provider_string_clone :: proc(
    value: string,
    allocator: mem.Allocator,
) -> (
    owned: string,
    err: Provider_Definition_Error,
) {
    allocation_err: runtime.Allocator_Error
    owned, allocation_err = strings.clone(value, allocator)
    if allocation_err != nil {
        return "", .Out_Of_Memory
    }

    return owned, .None
}

provider_string_concatenate :: proc(
    values: []string,
    allocator: mem.Allocator,
) -> (
    owned: string,
    err: Provider_Definition_Error,
) {
    allocation_err: runtime.Allocator_Error
    owned, allocation_err = strings.concatenate(values, allocator)
    if allocation_err != nil {
        return "", .Out_Of_Memory
    }

    return owned, .None
}

provider_captures_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "provider capture cleanup needs daemon state")
    assert(
        d.providers.capture_bytes >= 0 && d.providers.capture_bytes <= PROVIDER_DEFINITIONS_MAX_BYTES,
        "provider capture cleanup found invalid accounting",
    )

    for &capture in d.providers.captures {
        delete(capture.id, d.allocator)
        secret.string_destroy(&capture.definition, d.allocator)
    }
    delete(d.providers.captures)
    d.providers.captures = nil
    d.providers.capture_bytes = 0
    d.providers.capture_oom = false
    d.providers.registration_open = false
}

provider_definitions_destroy :: proc(d: ^Daemon) {
    assert(d != nil, "provider definition cleanup needs daemon state")

    provider_captures_destroy(d)
    provider_definition_slice_destroy(d.providers.definitions, d.allocator)
    d.providers.definitions = nil
}

provider_definition_slice_destroy :: proc(definitions: []Provider_Definition, allocator: mem.Allocator) {
    for &definition in definitions {
        provider_definition_destroy(&definition, allocator)
    }
    delete(definitions, allocator)
}

provider_definition_destroy :: proc(definition: ^Provider_Definition, allocator: mem.Allocator) {
    assert(definition != nil, "provider definition cleanup needs a definition")

    delete(definition.id, allocator)
    delete(definition.name, allocator)
    delete(definition.base_url, allocator)
    for name in definition.credential_env {
        delete(name, allocator)
    }
    delete(definition.credential_env, allocator)
    delete(definition.models_dev, allocator)
    model_definition_slice_destroy(definition.models, allocator)
    definition^ = {}
}

model_definition_slice_destroy :: proc(models: []Model_Definition, allocator: mem.Allocator) {
    for &model in models {
        model_definition_destroy(&model, allocator)
    }
    delete(models, allocator)
}

model_definition_destroy :: proc(model: ^Model_Definition, allocator: mem.Allocator) {
    assert(model != nil, "model definition cleanup needs a model")

    delete(model.id, allocator)
    delete(model.upstream_id, allocator)
    delete(model.name, allocator)
    for level in model.reasoning_levels {
        delete(level, allocator)
    }
    delete(model.reasoning_levels, allocator)
    delete(model.default_reasoning, allocator)
    model^ = {}
}
