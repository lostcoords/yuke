package wire

import "core:math"
import "core:strconv"
import "core:strings"

// Catalog content hash. @fixed 64
Catalog_Rev :: distinct [64]u8

// Provider model identifier string. @bounded 128
Model_Id :: string

// United States dollars per million tokens.
Model_Cost :: struct {
    // Cost per million input tokens.
    input:       f64,

    // Cost per million output tokens.
    output:      f64,

    // Cost per million cache-read tokens.
    cache_read:  f64,

    // Cost per million cache-write tokens.
    cache_write: f64,
}

// Write a Model_Cost object.
model_cost_emit :: proc(e: ^Emitter, self: Model_Cost) {
    object_begin(e)
    _field_f64(e, "input", self.input)
    _field_f64(e, "output", self.output)
    _field_f64(e, "cache_read", self.cache_read)
    _field_f64(e, "cache_write", self.cache_write)
    object_end(e)
}

// Closed projection of a provider model record. Non-owning.
Model_Info :: struct {
    // Model identifier.
    id:                Model_Id,

    // @bounded 64
    provider:          string,

    // @bounded 128
    name:              string,

    // Max input tokens the model accepts.
    context_window:    u64,

    // Max output tokens the model can produce.
    max_output_tokens: u64,

    // Supported reasoning effort levels. At most 32, each @bounded 32.
    reasoning_levels:  []string,

    // @bounded 32
    default_reasoning: string,

    // Whether the model accepts image input.
    supports_vision:   bool,

    // Whether the model supports tool calling.
    supports_tools:    bool,

    // Per-token pricing.
    cost:              Model_Cost,
}

// Write a Model_Info object.
model_info_emit :: proc(e: ^Emitter, self: Model_Info) {
    object_begin(e)
    field_string(e, "id", self.id)
    field_string(e, "provider", self.provider)
    field_string(e, "name", self.name)
    field_u64(e, "context_window", self.context_window)
    field_u64(e, "max_output_tokens", self.max_output_tokens)
    key(e, "reasoning_levels")
    array_begin(e)
    for level in self.reasoning_levels {
        elem(e)
        val_string(e, level)
    }

    array_end(e)
    field_string(e, "default_reasoning", self.default_reasoning)
    field_bool(e, "supports_vision", self.supports_vision)
    field_bool(e, "supports_tools", self.supports_tools)
    key(e, "cost")
    model_cost_emit(e, self.cost)
    object_end(e)
}

// Verify annotated field bounds.
model_info_validate :: proc(self: Model_Info) -> Validation_Error {
    enforce_bounded(128, self.id) or_return
    enforce_bounded(64, self.provider) or_return
    enforce_bounded(128, self.name) or_return
    enforce_bounded(32, self.default_reasoning) or_return

    if len(self.reasoning_levels) > LIMITS.max_reasoning_levels {
        return .Overflow
    }

    for level in self.reasoning_levels {
        enforce_bounded(32, level) or_return
    }

    costs := [4]f64{self.cost.input, self.cost.output, self.cost.cache_read, self.cost.cache_write}
    for c in costs {
        if math.is_nan(c) || math.is_inf(c) || c < 0 {
            return .Out_Of_Range
        }
    }

    return .None
}

// Params for catalog.list.
Catalog_List_Params :: struct {
    // Client's last known catalog revision; omit to force a full response.
    since_rev: Maybe(Catalog_Rev),
}

// Write catalog.list params, omitting `since_rev` when absent.
catalog_list_params_emit :: proc(e: ^Emitter, self: Catalog_List_Params) {
    object_begin(e)

    if rev, ok := self.since_rev.?; ok {
        field_id(e, "since_rev", ([64]u8)(rev))
    }

    object_end(e)
}

// Client's revision is current; no catalog data included.
Catalog_List_Result_Unchanged :: struct {
    // Current catalog revision.
    catalog_rev: Catalog_Rev,
}

// Client's revision was stale or absent; full catalog included.
Catalog_List_Result_Full :: struct {
    // Current catalog revision.
    catalog_rev: Catalog_Rev,

    // All available models.
    models:      []Model_Info,

    // Catalog load health.
    health:      Catalog_Health,
}

// Result of catalog.list: unchanged since `since_rev`, or a full catalog snapshot.
Catalog_List_Result :: union {
    Catalog_List_Result_Unchanged,
    Catalog_List_Result_Full,
}

// Write internally-tagged JSON with `type` first.
catalog_list_result_emit :: proc(e: ^Emitter, self: Catalog_List_Result) {
    object_begin(e)

    switch v in self {
    case Catalog_List_Result_Unchanged:
        field_string(e, "type", "unchanged")
        field_id(e, "catalog_rev", ([64]u8)(v.catalog_rev))

    case Catalog_List_Result_Full:
        field_string(e, "type", "full")
        field_id(e, "catalog_rev", ([64]u8)(v.catalog_rev))
        key(e, "models")
        array_begin(e)
        for model in v.models {
            elem(e)
            model_info_emit(e, model)
        }

        array_end(e)
        key(e, "health")
        catalog_health_emit(e, v.health)
    }

    object_end(e)
}

// Verify annotated field bounds.
catalog_list_result_validate :: proc(self: Catalog_List_Result) -> Validation_Error {
    switch v in self {
    case Catalog_List_Result_Unchanged:
        return enforce_id(([64]u8)(v.catalog_rev))

    case Catalog_List_Result_Full:
        enforce_id(([64]u8)(v.catalog_rev)) or_return

        if len(v.models) > LIMITS.max_catalog_models {
            return .Overflow
        }

        for model in v.models {
            model_info_validate(model) or_return
        }

        return catalog_health_validate(v.health)
    }

    return .None
}

// Result of catalog.refresh.
Catalog_Refresh_Result :: struct {
    // New catalog revision after refresh.
    catalog_rev: Catalog_Rev,

    // Catalog load health.
    health:      Catalog_Health,
}

// Write a catalog.refresh result.
catalog_refresh_result_emit :: proc(e: ^Emitter, self: Catalog_Refresh_Result) {
    object_begin(e)
    field_id(e, "catalog_rev", ([64]u8)(self.catalog_rev))
    key(e, "health")
    catalog_health_emit(e, self.health)
    object_end(e)
}

// Verify annotated field bounds.
catalog_refresh_result_validate :: proc(self: Catalog_Refresh_Result) -> Validation_Error {
    enforce_id(([64]u8)(self.catalog_rev)) or_return

    return catalog_health_validate(self.health)
}

// Catalog load health.
Catalog_Health :: struct {
    // Providers skipped by the daemon.
    skipped:    []Skipped_Provider,

    // Catalog load failure, if any. @bounded 4096
    load_error: Maybe(string),
}

// Write a Catalog_Health object. `load_error` is always emitted, null when absent.
catalog_health_emit :: proc(e: ^Emitter, self: Catalog_Health) {
    object_begin(e)
    key(e, "skipped")
    array_begin(e)
    for item in self.skipped {
        elem(e)
        skipped_provider_emit(e, item)
    }

    array_end(e)
    key(e, "load_error")

    if msg, ok := self.load_error.?; ok {
        val_string(e, msg)
    } else {
        val_null(e)
    }

    object_end(e)
}

// Verify annotated field bounds.
catalog_health_validate :: proc(self: Catalog_Health) -> Validation_Error {
    if len(self.skipped) > LIMITS.max_skipped_providers {
        return .Overflow
    }

    for item in self.skipped {
        skipped_provider_validate(item) or_return
    }

    if msg, ok := self.load_error.?; ok {
        return enforce_bounded(LIMITS.max_error_message_bytes, msg)
    }

    return .None
}

// Deep-copy into `allocator`.
catalog_health_clone :: proc(self: Catalog_Health, allocator := context.allocator) -> Catalog_Health {
    // Iterate the destination length: a failed `make` yields a zero-length slice, so this
    // under-copies gracefully instead of indexing out of bounds under allocation failure.
    skipped := make([]Skipped_Provider, len(self.skipped), allocator)
    for i in 0 ..< len(skipped) {
        skipped[i] = skipped_provider_clone(self.skipped[i], allocator)
    }

    load_error: Maybe(string)

    if msg, ok := self.load_error.?; ok {
        load_error = strings.clone(msg, allocator)
    }

    return Catalog_Health{skipped = skipped, load_error = load_error}
}

// Providers skipped during catalog load. Non-owning.
Skipped_Provider :: struct {
    // Provider name. @bounded 64
    provider: string,

    // Why this provider was skipped.
    reason:   Skip_Reason,
}

// Write a Skipped_Provider object.
skipped_provider_emit :: proc(e: ^Emitter, self: Skipped_Provider) {
    object_begin(e)
    field_string(e, "provider", self.provider)
    key(e, "reason")
    skip_reason_emit(e, self.reason)
    object_end(e)
}

// Verify annotated field bounds.
skipped_provider_validate :: proc(self: Skipped_Provider) -> Validation_Error {
    enforce_bounded(64, self.provider) or_return

    return skip_reason_validate(self.reason)
}

// Deep-copy into `allocator`.
skipped_provider_clone :: proc(self: Skipped_Provider, allocator := context.allocator) -> Skipped_Provider {
    return Skipped_Provider {
        provider = strings.clone(self.provider, allocator),
        reason = skip_reason_clone(self.reason, allocator),
    }
}

// Required credential was absent.
Skip_Reason_Missing_Credential :: struct {
    // Environment variable name. @bounded 256
    env: string,
}

// Provider config was invalid.
Skip_Reason_Invalid_Config :: struct {
    // Human-readable error. @bounded 4096
    message: string,
}

// Reason a provider was skipped.
Skip_Reason :: union {
    Skip_Reason_Missing_Credential,
    Skip_Reason_Invalid_Config,
}

// Write internally-tagged JSON with `type` first.
skip_reason_emit :: proc(e: ^Emitter, self: Skip_Reason) {
    object_begin(e)

    switch v in self {
    case Skip_Reason_Missing_Credential:
        field_string(e, "type", "missing_credential")
        field_string(e, "env", v.env)

    case Skip_Reason_Invalid_Config:
        field_string(e, "type", "invalid_config")
        field_string(e, "message", v.message)
    }

    object_end(e)
}

// Verify the nested diagnostic bound.
skip_reason_validate :: proc(self: Skip_Reason) -> Validation_Error {
    switch v in self {
    case Skip_Reason_Missing_Credential:
        return enforce_bounded(256, v.env)

    case Skip_Reason_Invalid_Config:
        return enforce_bounded(LIMITS.max_error_message_bytes, v.message)
    }

    return .None
}

// Deep-copy into `allocator`. Both arms own a slice.
skip_reason_clone :: proc(self: Skip_Reason, allocator := context.allocator) -> Skip_Reason {
    switch v in self {
    case Skip_Reason_Missing_Credential:
        return Skip_Reason_Missing_Credential{env = strings.clone(v.env, allocator)}

    case Skip_Reason_Invalid_Config:
        return Skip_Reason_Invalid_Config{message = strings.clone(v.message, allocator)}
    }

    return nil
}

// Write a bare f64 value in decimal, without a leading plus sign.
@(private)
_val_f64 :: proc(e: ^Emitter, f: f64) {
    buf: [32]u8
    s := strconv.write_float(buf[:], f, 'f', -1, 64)

    if len(s) > 0 && s[0] == '+' {
        s = s[1:]
    }

    strings.write_string(&e.sb, s)
}

// Write a `name: f64` object field.
@(private)
_field_f64 :: proc(e: ^Emitter, name: string, f: f64) {
    key(e, name)
    _val_f64(e, f)
}

// --- streaming decoders ---

// Decode a Model_Cost straight from the token stream.
model_cost_from_reader :: proc(d: ^Decoder) -> (cost: Model_Cost, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        In,
        Out,
        Cr,
        Cw,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "input":
            cost.input = dec_f64(d) or_return
            seen += {.In}

        case "output":
            cost.output = dec_f64(d) or_return
            seen += {.Out}

        case "cache_read":
            cost.cache_read = dec_f64(d) or_return
            seen += {.Cr}

        case "cache_write":
            cost.cache_write = dec_f64(d) or_return
            seen += {.Cw}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.In, .Out, .Cr, .Cw} {
        return {}, .Mismatched_Payload
    }

    return cost, .None
}

// Decode a Model_Info straight from the token stream.
model_info_from_reader :: proc(d: ^Decoder) -> (info: Model_Info, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Prov,
        Name,
        Ctx,
        Max,
        Levels,
        Def,
        Vis,
        Tools,
        Cost,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            info.id = dec_string(d) or_return
            seen += {.Id}

        case "provider":
            info.provider = dec_string(d) or_return
            seen += {.Prov}

        case "name":
            info.name = dec_string(d) or_return
            seen += {.Name}

        case "context_window":
            info.context_window = dec_u64(d) or_return
            seen += {.Ctx}

        case "max_output_tokens":
            info.max_output_tokens = dec_u64(d) or_return
            seen += {.Max}

        case "reasoning_levels":
            info.reasoning_levels = dec_array(d, dec_string) or_return
            seen += {.Levels}

        case "default_reasoning":
            info.default_reasoning = dec_string(d) or_return
            seen += {.Def}

        case "supports_vision":
            info.supports_vision = dec_bool(d) or_return
            seen += {.Vis}

        case "supports_tools":
            info.supports_tools = dec_bool(d) or_return
            seen += {.Tools}

        case "cost":
            info.cost = model_cost_from_reader(d) or_return
            seen += {.Cost}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Prov, .Name, .Ctx, .Max, .Levels, .Def, .Vis, .Tools, .Cost} {
        return {}, .Mismatched_Payload
    }

    return info, .None
}

// Decode catalog.list params straight from the token stream.
catalog_list_params_from_reader :: proc(d: ^Decoder) -> (params: Catalog_List_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "since_rev":
            if !dec_is_null(d) {
                params.since_rev = Catalog_Rev(dec_fixed(d, 64) or_return)
            }

        case:
            dec_skip(d) or_return
        }
    }

    return params, .None
}

// Decode internally-tagged catalog.list result straight from the token stream.
catalog_list_result_from_reader :: proc(d: ^Decoder) -> (result: Catalog_List_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "unchanged":
        rev: [64]u8
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "catalog_rev":
                rev = dec_fixed(d, 64) or_return
                have = true

            case "models", "health":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Catalog_List_Result_Unchanged{catalog_rev = Catalog_Rev(rev)}, .None

    case "full":
        rev: [64]u8
        models: []Model_Info
        health: Catalog_Health

        Field :: enum {
            Rev,
            Models,
            Health,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "catalog_rev":
                rev = dec_fixed(d, 64) or_return
                seen += {.Rev}

            case "models":
                models = dec_array(d, model_info_from_reader) or_return
                seen += {.Models}

            case "health":
                health = catalog_health_from_reader(d) or_return
                seen += {.Health}

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Rev, .Models, .Health} {
            return nil, .Mismatched_Payload
        }

        return Catalog_List_Result_Full{catalog_rev = Catalog_Rev(rev), models = models, health = health}, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a catalog.refresh result straight from the token stream.
catalog_refresh_result_from_reader :: proc(d: ^Decoder) -> (result: Catalog_Refresh_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Rev,
        Health,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "catalog_rev":
            result.catalog_rev = Catalog_Rev(dec_fixed(d, 64) or_return)
            seen += {.Rev}

        case "health":
            result.health = catalog_health_from_reader(d) or_return
            seen += {.Health}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Rev, .Health} {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode a Catalog_Health straight from the token stream.
catalog_health_from_reader :: proc(d: ^Decoder) -> (health: Catalog_Health, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Skipped,
        Load,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "skipped":
            health.skipped = dec_array(d, skipped_provider_from_reader) or_return
            seen += {.Skipped}

        case "load_error":
            seen += {.Load}

            if !dec_is_null(d) {
                health.load_error = dec_string(d) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Skipped, .Load} {
        return {}, .Mismatched_Payload
    }

    return health, .None
}

// Decode a Skipped_Provider straight from the token stream.
skipped_provider_from_reader :: proc(d: ^Decoder) -> (item: Skipped_Provider, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Prov,
        Reason,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "provider":
            item.provider = dec_string(d) or_return
            seen += {.Prov}

        case "reason":
            item.reason = skip_reason_from_reader(d) or_return
            seen += {.Reason}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Prov, .Reason} {
        return {}, .Mismatched_Payload
    }

    return item, .None
}

// Decode internally-tagged skip reason straight from the token stream.
skip_reason_from_reader :: proc(d: ^Decoder) -> (reason: Skip_Reason, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "missing_credential":
        env: string
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "env":
                env = dec_string(d) or_return
                have = true

            case "message":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Skip_Reason_Missing_Credential{env = env}, .None

    case "invalid_config":
        message: string
        have := false
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "message":
                message = dec_string(d) or_return
                have = true

            case "env":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if !have {
            return nil, .Mismatched_Payload
        }

        return Skip_Reason_Invalid_Config{message = message}, .None
    }

    return nil, .Mismatched_Payload
}
