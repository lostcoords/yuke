package schema

import "core:fmt"
import "core:strings"
import "libs:json"

// JSON Schema 2020-12 over the same model `wire.json` is built from, for validators, docs
// renderers, and fuzzers. It describes the bytes on the wire, where `wire.json` describes the
// protocol; neither is derived from the other, because each is lossy for the other's audience.
//
// Two things it structurally cannot carry, and does not pretend to: message direction and a
// broadcast's delivery class. ACP needed a non-standard `x-side` for the first. Both live in
// `wire.json`.
//
// A success response is the one frame that is not self-describing — the daemon takes the method
// from the caller's pending-id map — so the root validates requests, notifications, and error
// responses, and exposes each method's success response as its own definition for a client that
// knows what it sent.
//
// Built as a `json.Value` tree because schema nodes are recursive and heterogeneous, and core's
// marshal rejects pointers. Object keys serialize sorted, which is deterministic; key order
// carries no meaning in JSON.

// Build the schema document.
jsonschema_build :: proc(m: ^Model) -> json.Object {
    assert(m != nil, "jsonschema_build needs a model")

    defs := make(json.Object)

    for s in m.structs {
        defs[s.name] = struct_schema(m, s)
    }

    for u in m.unions {
        if u.discriminator != "" {
            defs[u.name] = union_schema(m, u)

            continue
        }

        // Tagged from outside the payload: the arms are all that can be said, and `anyOf` rather
        // than `oneOf` because several arms are structurally identical (a shared result type, an
        // empty object). Such a union cannot be validated without knowing the frame's method.
        arms := make(json.Array, 0, len(u.arms))

        for arm in u.arms {
            append(&arms, ref(arm.type))
        }

        node := make(json.Object)
        node["description"] = json.Value(u.doc)
        node["anyOf"] = arms
        defs[u.name] = node
    }

    for e in m.enums {
        defs[e.name] = enum_schema(e)
    }

    for a in m.aliases {
        defs[a.name] = type_schema(m, a.base, a.bound, a.doc)
    }

    requests := make(json.Array, 0, len(m.methods))

    for method in m.methods {
        append(&requests, request_schema(method))
        defs[fmt.aprintf("Response_%s", method.name)] = response_schema(method)
    }

    notifications := make(json.Array, 0, len(m.broadcasts))

    for b in m.broadcasts {
        append(&notifications, notification_schema(b))
    }

    request := make(json.Object)
    request["description"] = json.Value(
        "A JSON-RPC request. `method` is a const per arm, so a frame selects its own params type.",
    )
    request["oneOf"] = requests
    defs["Request"] = request
    notification := make(json.Object)
    notification["description"] = json.Value("A server-pushed notification. No `id`, so nothing replies.")
    notification["oneOf"] = notifications
    defs["Notification"] = notification
    defs["Response_Error"] = response_error_schema()
    defs["Request_Id"] = request_id_schema()

    root_arms := make(json.Array, 0, 3)
    append(&root_arms, ref("Request"), ref("Notification"), ref("Response_Error"))
    root := make(json.Object)
    root["$schema"] = json.Value("https://json-schema.org/draft/2020-12/schema")
    root["title"] = json.Value(fmt.aprintf("yuke wire protocol v%d", m.protocol_version))
    root["description"] = json.Value(
        "Frames a client may send and a daemon may push. A success response is not self-describing: validate it against the `Response_<Method>` definition for the method that was sent.",
    )
    root["oneOf"] = root_arms
    root["$defs"] = defs

    return root
}

ref :: proc(name: string) -> json.Value {
    out := make(json.Object)
    out["$ref"] = json.Value(fmt.aprintf("#/$defs/%s", name))

    return out
}

scalar :: proc(type: string) -> json.Object {
    out := make(json.Object)
    out["type"] = json.Value(type)

    return out
}

konst :: proc(value: string) -> json.Value {
    out := make(json.Object)
    out["type"] = json.Value("string")
    out["const"] = json.Value(value)

    return out
}

// `not: {required: [key]}` — the member must be absent. The envelope rules are exclusions:
// a notification carries no `id`, and a response carries `result` xor `error`.
forbids :: proc(key: string) -> json.Value {
    required := make(json.Object)
    required["required"] = strings_array(key)
    out := make(json.Object)
    out["not"] = required

    return out
}

strings_array :: proc(values: ..string) -> json.Array {
    out := make(json.Array, 0, len(values))

    for v in values {
        append(&out, json.Value(v))
    }

    return out
}

// The JSON-RPC envelope members every frame carries.
envelope :: proc(with_id: bool) -> json.Object {
    props := make(json.Object)
    props["jsonrpc"] = konst("2.0")

    if with_id do props["id"] = ref("Request_Id")

    return props
}

request_schema :: proc(method: Method) -> json.Value {
    props := envelope(true)
    props["method"] = konst(method.wire)
    props["params"] = ref(method.params_type)
    out := make(json.Object)
    out["type"] = json.Value("object")
    out["description"] = json.Value(method.doc)
    out["properties"] = props

    // An omittable `params` has a daemon-supplied default, so its absence is legal.
    if method.params_optional {
        out["required"] = strings_array("jsonrpc", "id", "method")
    } else {
        out["required"] = strings_array("jsonrpc", "id", "method", "params")
    }

    return out
}

response_schema :: proc(method: Method) -> json.Value {
    props := envelope(true)
    props["result"] = ref(method.result_type)
    out := make(json.Object)
    out["type"] = json.Value("object")
    out["description"] = json.Value(fmt.aprintf("Success response to `%s`.", method.wire))
    out["properties"] = props
    out["required"] = strings_array("jsonrpc", "id", "result")
    out["not"] = forbids("error").(json.Object)["not"]

    return out
}

notification_schema :: proc(b: Broadcast) -> json.Value {
    props := envelope(false)
    props["method"] = konst(b.wire)
    props["params"] = ref(b.params_type)
    out := make(json.Object)
    out["type"] = json.Value("object")
    out["description"] = json.Value(b.doc)
    out["properties"] = props
    out["required"] = strings_array("jsonrpc", "method", "params")
    // A notification has no `id`; one that carries it is a framing violation, not a response.
    out["not"] = forbids("id").(json.Object)["not"]

    return out
}

response_error_schema :: proc() -> json.Value {
    props := envelope(true)
    props["error"] = ref("Error_Object")
    out := make(json.Object)
    out["type"] = json.Value("object")
    out["description"] = json.Value(
        "Failed response. Carries `error` instead of `result`; the two never appear together.",
    )
    out["properties"] = props
    out["required"] = strings_array("jsonrpc", "id", "error")
    out["not"] = forbids("result").(json.Object)["not"]

    return out
}

// A correlation id is opaque: JSON-RPC permits string, number, or null, and the response must
// echo whatever the request sent.
request_id_schema :: proc() -> json.Value {
    arms := make(json.Array, 0, 3)
    append(&arms, json.Value(scalar("string")), json.Value(scalar("number")), json.Value(scalar("null")))
    out := make(json.Object)
    out["description"] = json.Value("Correlation id, echoed verbatim. Opaque to the daemon.")
    out["anyOf"] = arms

    return out
}

struct_schema :: proc(m: ^Model, s: Struct_Def) -> json.Value {
    props := make(json.Object)
    required := make([dynamic]string, 0, len(s.fields))

    for f in s.fields {
        props[f.name] = field_schema(m, f)

        if field_is_required(f) do append(&required, f.name)
    }

    out := make(json.Object)
    out["type"] = json.Value("object")
    out["description"] = json.Value(s.doc)
    out["properties"] = props
    out["required"] = strings_array(..required[:])

    return out
}

// Optional, optional-nullable, and defaulted fields may be absent. `requiredNullable` always
// writes the key with null as its value.
field_is_required :: proc(f: Field) -> bool {
    return f.presence != .Optional && f.presence != .Optional_Nullable && f.presence != .Defaulted
}

// A field's schema, admitting `null` where the wire accepts it: as the value of a
// `requiredNullable` member, or as an accepted-but-collapsed absence for `optionalNullable`.
field_schema :: proc(m: ^Model, f: Field) -> json.Value {
    if f.presence != .Required_Nullable && f.presence != .Optional_Nullable {
        out := type_schema(m, f.type_expr, f.bound, f.doc)

        if value, ok := f.const_value.?; ok {
            if object, is_object := out.(json.Object); is_object do object["const"] = json.Value(i64(value))
        }

        return out
    }

    arms := make(json.Array, 0, 2)
    append(&arms, type_schema(m, f.type_expr, f.bound, ""), json.Value(scalar("null")))
    out := make(json.Object)
    out["description"] = json.Value(f.doc)
    out["anyOf"] = arms

    return out
}

// Map a declared wire type onto JSON Schema. A named type becomes a `$ref`, which the reference
// gate has already proven resolves.
type_schema :: proc(m: ^Model, type_expr: string, bound: Bound, doc: string) -> json.Value {
    if strings.has_prefix(type_expr, "Maybe(") && strings.has_suffix(type_expr, ")") do return type_schema(m, type_expr[len("Maybe("):len(type_expr) - 1], bound, doc)

    if strings.has_prefix(type_expr, "[]") {
        out := make(json.Object)
        out["type"] = json.Value("array")
        out["items"] = type_schema(m, type_expr[2:], Bound{}, "")

        if bound.kind == .Bounded do out["maxItems"] = json.Value(i64(bound.value))

        return described(out, doc)
    }

    // `[N]u8` is an N-character lowercase hex string on the wire, not an array of numbers.
    if count, is_hex := hex_length(type_expr); is_hex {
        out := scalar("string")
        out["minLength"] = json.Value(i64(count))
        out["maxLength"] = json.Value(i64(count))
        out["pattern"] = json.Value(fmt.aprintf("^[0-9a-f]{{%d}}$", count))

        return described(out, doc)
    }

    switch type_expr {
    case "string":
        out := scalar("string")

        switch bound.kind {
        case .Bounded:
            out["maxLength"] = json.Value(i64(bound.value))
            out["x-maxUtf8Bytes"] = json.Value(i64(bound.value))

        case .Fixed:
            out["maxLength"] = json.Value(i64(bound.value))
            out["x-minUtf8Bytes"] = json.Value(i64(bound.value))
            out["x-maxUtf8Bytes"] = json.Value(i64(bound.value))

        case .Unbounded, .Missing:
        }

        return described(out, doc)

    case "bool":
        return described(scalar("boolean"), doc)

    case "f64", "f32":
        return described(scalar("number"), doc)

    case "u64", "u32", "u16", "u8", "i64", "i32", "i16", "i8", "int":
        return described(integer_schema(m, type_expr), doc)
    }

    // A `$ref` cannot carry sibling keywords in 2020-12 without them being ignored, so the doc is
    // dropped rather than written somewhere it has no effect.
    return ref(type_expr)
}

described :: proc(node: json.Object, doc: string) -> json.Value {
    node := node

    if doc != "" do node["description"] = json.Value(doc)

    return node
}

// Every integer on the wire is a JSON number, so it is capped at the safe-integer range the decode
// boundary enforces.
integer_schema :: proc(m: ^Model, type_expr: string) -> json.Object {
    out := scalar("integer")
    safe := m.consts["MAX_WIRE_INTEGER"]
    minimum, maximum := -safe, safe

    switch type_expr {
    case "u64":
        minimum = 0
    case "u32":
        minimum, maximum = 0, min(maximum, 4_294_967_295)
    case "u16":
        minimum, maximum = 0, min(maximum, 65_535)
    case "u8":
        minimum, maximum = 0, min(maximum, 255)
    case "i32":
        minimum, maximum = max(minimum, -2_147_483_648), min(maximum, 2_147_483_647)
    case "i16":
        minimum, maximum = max(minimum, -32_768), min(maximum, 32_767)
    case "i8":
        minimum, maximum = max(minimum, -128), min(maximum, 127)
    case "i64", "int":
    }

    out["minimum"] = json.Value(i64(minimum))
    out["maximum"] = json.Value(i64(maximum))

    return out
}

// `[N]u8` -> N.
hex_length :: proc(type_expr: string) -> (count: int, ok: bool) {
    if !strings.has_prefix(type_expr, "[") || !strings.has_suffix(type_expr, "]u8") do return 0, false

    digits := type_expr[1:len(type_expr) - len("]u8")]

    if len(digits) == 0 do return 0, false

    for i in 0 ..< len(digits) {
        if digits[i] < '0' || digits[i] > '9' do return 0, false

        count = count * 10 + int(digits[i] - '0')
    }

    return count, count > 0
}

// A `type`-tagged union becomes a `oneOf` whose arms each pin the discriminator with a `const`.
// That const is what makes it a discriminated union for a consumer — the thing ACP's schema leaves
// out, forcing its generated SDK to hardcode the dispatch table.
union_schema :: proc(m: ^Model, u: Union_Def) -> json.Value {
    arms := make(json.Array, 0, len(u.arms))

    for arm in u.arms {
        props := make(json.Object)
        props[u.discriminator] = konst(arm.tag)
        required := make([dynamic]string, 0, 4)
        append(&required, u.discriminator)

        if s := model_struct(m, arm.type); s != nil {
            for f in s.fields {
                props[f.name] = field_schema(m, f)

                if field_is_required(f) do append(&required, f.name)
            }
        }

        node := make(json.Object)
        node["type"] = json.Value("object")
        node["title"] = json.Value(arm.type)
        node["properties"] = props
        node["required"] = strings_array(..required[:])
        append(&arms, json.Value(node))
    }

    out := make(json.Object)
    out["description"] = json.Value(u.doc)
    out["oneOf"] = arms

    return out
}

enum_schema :: proc(e: Enum_Def) -> json.Value {
    values := make(json.Array, 0, len(e.values))

    for v in e.values {
        if !e.numeric {
            append(&values, json.Value(v.wire))

            continue
        }

        if n, ok := parse_i32(v.wire); ok do append(&values, json.Value(i64(n)))
    }

    out := scalar(e.numeric ? "integer" : "string")
    out["description"] = json.Value(e.doc)
    out["enum"] = values

    return out
}
