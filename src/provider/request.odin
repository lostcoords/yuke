package provider

import "base:runtime"
import "core:encoding/json"
import "core:unicode/utf8"
import "src:wire"

// One callable tool exposed to a provider. `input_schema` is exactly one JSON
// object and is validated by the protocol request builder before transmission.
Tool_Definition :: struct {
    // Provider-visible tool name.
    name:         string,

    // Provider-visible description.
    description:  string,

    // JSON Schema object for the tool arguments.
    input_schema: string,
}

// Provider-neutral input for one model turn. Every string and transcript slice
// is borrowed; a protocol builder produces an owned request body.
Request :: struct {
    // Resolved provider model id.
    model:             string,

    // System prompt, omitted when absent or empty.
    system_prompt:     Maybe(string),

    // Canonical folded transcript in message order.
    messages:          []wire.Message,

    // Tools available during this turn.
    tools:             []Tool_Definition,

    // Strict output-token ceiling. Providers that require this field receive it
    // verbatim; catalog resolution, not the builder, chooses the model limit.
    max_output_tokens: u64,

    // Optional sampling temperature. Model resolution is responsible for
    // omitting it on models that reject sampling controls.
    temperature:       Maybe(f64),
}

// Shared tool preflight for every protocol: each tool needs a non-empty valid
// UTF-8 name of at most 128 bytes, a valid UTF-8 description, a name unique
// within the set, and a structurally valid JSON-object input schema. Each schema
// is parsed into `scratch_allocator`, which must be a bulk-reclaimable scope.
@(private)
tools_validate :: proc(tools: []Tool_Definition, scratch_allocator: runtime.Allocator) -> Transport_Error {
    for tool, index in tools {
        if len(tool.name) == 0 ||
           len(tool.name) > 128 ||
           !utf8.valid_string(tool.name) ||
           !utf8.valid_string(tool.description) {
            return .Invalid_Request
        }

        for prior in tools[:index] {
            if tool.name == prior.name {
                return .Invalid_Request
            }
        }

        value, _, parse_err := decode_json_object(tool.input_schema, scratch_allocator)
        if parse_err != .None {
            return parse_err == .Resource_Exhausted ? .Resource_Exhausted : .Invalid_Request
        }

        json.destroy_value(value, scratch_allocator)
    }

    return .None
}
