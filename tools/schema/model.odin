package schema

import "tools:gen"

// Which length rule a field declares. Every wire string and array field carries
// exactly one; `src/wire` is swept so that absence is a defect, not a default.
Bound_Kind :: enum {
    // No marker found. Always a diagnostic for a string or array field.
    Missing,

    // `@bounded X` — max bytes for a string, max elements for an array.
    Bounded,

    // `@fixed N` — exact byte length.
    Fixed,

    // `@unbounded` — deliberately uncapped, declared so the omission is reviewable.
    Unbounded,
}

// A declared length rule plus the resolution of its expression.
Bound :: struct {
    kind:  Bound_Kind,

    // Marker text exactly as written: `128`, `LIMITS.max_page_size`,
    // `MAX_REQUEST_ID_BYTES`. Kept verbatim so the cross-check compares what the
    // author wrote against what the validator reads.
    expr:  string,

    // `expr` evaluated against the constant table. An unresolvable marker is a hard
    // failure, so every model that reaches an emitter has this set.
    value: int,
}

// How a member's absence is encoded. A generated SDK that collapses these is wrong in
// a way JSON does not reveal, so the model names each form.
Presence :: enum {
    // Always written, always required on decode.
    Required,

    // Omitted when absent; an explicit `null` is malformed.
    Optional,

    // Omitted on input to select the decoder's declared default; canonical output
    // writes the resolved value.
    Defaulted,

    // Always written, `null` when absent. `null` is the value, not an absence.
    Required_Nullable,

    // Absent, explicit `null`, and a value are three distinct states.
    Tristate,
}

// One member of a wire struct.
Field :: struct {
    // Wire name. Equal to the Odin field name across `src/wire`.
    name:          string,

    // Source text of the declared type, unresolved (`Maybe(string)`, `[]Message`).
    type_expr:     string,

    // Human doc comment with the marker line removed.
    doc:           string,
    bound:         Bound,
    presence:      Presence,
    default_expr:  string,
    const_expr:    string,
    const_value:   Maybe(int),
    delivery_role: string,
    pos:           gen.Pos,
}

// A wire object.
Struct_Def :: struct {
    name:   string,
    doc:    string,
    fields: []Field,
    pos:    gen.Pos,
}

// A wire union. `discriminator` is the member a decoder scans for; empty means the arm
// is selected from outside the payload (the frame's `method`, or member presence).
Union_Def :: struct {
    name:          string,
    doc:           string,
    arms:          []Union_Arm,
    discriminator: string,
    pos:           gen.Pos,
}

// One arm and the discriminator value that selects it. `tag` is empty for a union whose arm
// is chosen from outside the payload.
Union_Arm :: struct {
    type:      string,
    tag:       string,

    // How the arm appears on the wire, for a union the payload does not tag. A tri-state
    // override has one arm of each form, and a consumer cannot encode the field without
    // knowing which is which.
    form:      Arm_Form,

    // Wire type this arm carries, when `form` is `.Value`.
    wire_type: string,
}

// What an untagged union's arm writes.
Arm_Form :: enum {
    // Not applicable: the arm is selected by a discriminator or by the frame.
    None,

    // Nothing is written; the member is omitted entirely.
    Absent,

    // The member is written as `null`.
    Null,

    // The member is written as a scalar of `wire_type`.
    Value,
}

// One enum member and the string it takes on the wire.
Enum_Value :: struct {
    name: string,
    wire: string,
    doc:  string,
}

// A wire enum. An enum without a mapping table is internal and never reaches the wire,
// so it is not part of the model.
Enum_Def :: struct {
    name:    string,
    doc:     string,
    values:  []Enum_Value,

    // Name of the `[Enum]string` / `[Enum]i32` table this was read from.
    table:   string,

    // True for `[Enum]i32` tables, where the wire form is a number.
    numeric: bool,
    pos:     gen.Pos,
}

// A `distinct` newtype over a scalar: the id and revision types.
Alias_Def :: struct {
    name:  string,
    base:  string,
    doc:   string,
    bound: Bound,
    pos:   gen.Pos,
}

// One request method. `params_type`/`result_type` are the linkage that exists nowhere
// declaratively in `src/wire` — they are read out of the dispatch switches.
Method :: struct {
    // Odin enum member (`Session_Create`).
    name:            string,

    // Dotted wire name (`session.create`).
    wire:            string,
    doc:             string,
    params_type:     string,
    result_type:     string,

    // The method accepts a frame with no `params` member.
    params_optional: bool,
}

// One server-pushed broadcast. `class` carries the sequencing, gating, and droppability
// rules that no standard schema format has a slot for.
Broadcast :: struct {
    name:          string,
    wire:          string,
    doc:           string,
    params_type:   string,
    class:         string,

    // Member carrying the per-session sequence number, for the gap check a receiver must do.
    // Read from `broadcast_data_seq`, so it is the field the daemon actually stamps.
    seq_field:     string,
    session_field: string,
}

// A delivery class and the rules that apply to every broadcast in it. Sequencing, gating, and
// droppability are properties of the class, not of individual broadcasts.
Delivery_Class :: struct {
    name:      string,

    // Delivered only to connections subscribed to the payload's session.
    gated:     bool,

    // The daemon may shed one under send backpressure; the receiver detects the gap by offset
    // and resyncs rather than folding corrupt state.
    droppable: bool,

    // Carries a per-session sequence number a receiver must gap-check.
    sequenced: bool,
}

// One request-failure code and its durable JSON-RPC number.
Error_Def :: struct {
    name: string,
    doc:  string,
    code: i32,
}

// The whole protocol.
Model :: struct {
    protocol_version: int,

    // `LIMITS` fields, resolved.
    limits:           map[string]int,

    // Top-level `::` integer constants, resolved.
    consts:           map[string]int,

    // Top-level `::` string constants. `JSONRPC_VERSION` is protocol data a client must send.
    strings:          map[string]string,

    // WebSocket close codes the daemon uses. A client cannot interpret a close without them.
    close_codes:      map[string]int,
    structs:          [dynamic]Struct_Def,
    unions:           [dynamic]Union_Def,
    enums:            [dynamic]Enum_Def,
    aliases:          [dynamic]Alias_Def,
    methods:          [dynamic]Method,
    broadcasts:       [dynamic]Broadcast,
    delivery_classes: [dynamic]Delivery_Class,
    errors:           [dynamic]Error_Def,
}

// Look up a struct by name; nil when absent.
model_struct :: proc(m: ^Model, name: string) -> ^Struct_Def {
    assert(m != nil, "model_struct needs a model")

    for &s in m.structs {
        if s.name == name do return &s
    }

    return nil
}

// Look up a union by name; nil when absent.
model_union :: proc(m: ^Model, name: string) -> ^Union_Def {
    assert(m != nil, "model_union needs a model")

    for &u in m.unions {
        if u.name == name do return &u
    }

    return nil
}

// Look up an enum by name; nil when absent.
model_enum :: proc(m: ^Model, name: string) -> ^Enum_Def {
    assert(m != nil, "model_enum needs a model")

    for &e in m.enums {
        if e.name == name do return &e
    }

    return nil
}
