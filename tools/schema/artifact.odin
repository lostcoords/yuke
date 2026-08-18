package schema

import "core:fmt"
import "core:strings"
import "libs:json"

// The published shape of `wire.json`, kept separate from `Model` on purpose: the model is
// this tool's internal working form and may be refactored freely, while these types are a
// contract other languages generate from. Tagging the model directly would let an internal
// rename silently change the published schema.
//
// Keys are camelCase to match the meta-models SDK generators already read (LSP's
// `metaModel.json`, ACP's `schema.json`). `limits` and `constants` keys are protocol data,
// so they keep their Odin spelling.

Artifact :: struct {
    protocol_version: int `json:"protocolVersion"`,
    limits:           map[string]int `json:"limits"`,
    constants:        map[string]int `json:"constants"`,
    string_constants: map[string]string `json:"stringConstants"`,
    close_codes:      map[string]int `json:"closeCodes"`,
    methods:          []Artifact_Method `json:"methods"`,
    broadcasts:       []Artifact_Broadcast `json:"broadcasts"`,
    delivery_classes: []Artifact_Delivery_Class `json:"deliveryClasses"`,
    errors:           []Artifact_Error `json:"errors"`,
    structures:       []Artifact_Struct `json:"structures"`,
    unions:           []Artifact_Union `json:"unions"`,
    enumerations:     []Artifact_Enum `json:"enumerations"`,
    aliases:          []Artifact_Alias `json:"aliases"`,
}

// A request. `direction` is stated even though every method is client-to-server, because a
// consumer must not have to infer it from the artifact's shape.
Artifact_Method :: struct {
    name:            string `json:"name"`,
    odin_name:       string `json:"odinName"`,
    direction:       string `json:"direction"`,
    doc:             string `json:"doc"`,
    params:          string `json:"params"`,
    result:          string `json:"result"`,
    params_optional: bool `json:"paramsOptional"`,
}

// A server-pushed notification. `class` carries the sequencing, gating, and droppability
// rules that no standard schema format has a slot for.
Artifact_Broadcast :: struct {
    name:          string `json:"name"`,
    odin_name:     string `json:"odinName"`,
    direction:     string `json:"direction"`,
    doc:           string `json:"doc"`,
    params:        string `json:"params"`,
    class:         string `json:"class"`,

    // Member carrying the per-session sequence number, when this broadcast is sequenced. A
    // receiver must gap-check it; absent means the broadcast is not sequenced.
    seq_field:     string `json:"seqField,omitempty"`,
    session_field: string `json:"sessionField,omitempty"`,
}

// Rules that apply to every broadcast in a class. A receiver's obligations follow from these:
// `sequenced` means gap-check the sequence number, `droppable` means the daemon may shed a frame
// and the receiver detects it by offset, `gated` means delivery follows the subscription set.
Artifact_Delivery_Class :: struct {
    name:      string `json:"name"`,
    gated:     bool `json:"gated"`,
    droppable: bool `json:"droppable"`,
    sequenced: bool `json:"sequenced"`,
}

// A request-failure code and its durable JSON-RPC number.
Artifact_Error :: struct {
    odin_name: string `json:"odinName"`,
    code:      i32 `json:"code"`,
    doc:       string `json:"doc"`,
}

Artifact_Struct :: struct {
    name:   string `json:"name"`,
    doc:    string `json:"doc"`,
    fields: []Artifact_Field `json:"fields"`,
}

// `presence` is the member's absence encoding, which JSON cannot show and an SDK must not
// collapse: `optional` is omitted and rejects an explicit null, `defaulted` selects a
// decoder default, `requiredNullable` always writes the key, and `tristate` distinguishes
// all three states.
Artifact_Field :: struct {
    name:          string `json:"name"`,
    type:          string `json:"type"`,
    doc:           string `json:"doc"`,
    presence:      string `json:"presence"`,
    default_expr:  string `json:"defaultExpr,omitempty"`,
    const_expr:    string `json:"constExpr,omitempty"`,
    const_value:   Maybe(int) `json:"constValue,omitempty"`,
    delivery_role: string `json:"deliveryRole,omitempty"`,
    bound:         Maybe(Artifact_Bound) `json:"bound,omitempty"`,
}

// A declared length rule. `expr` is the marker as written, so a consumer can see whether a
// bound is shared by name; `value` is it resolved.
Artifact_Bound :: struct {
    kind:  string `json:"kind"`,
    expr:  string `json:"expr"`,
    value: int `json:"value"`,
}

// `discriminator` is the member a decoder reads to pick an arm. Empty means the arm is
// chosen from outside the payload — the frame's `method`, or which member is present — and
// such a union cannot be validated standalone.
Artifact_Union :: struct {
    name:          string `json:"name"`,
    doc:           string `json:"doc"`,
    discriminator: string `json:"discriminator"`,
    arms:          []Artifact_Union_Arm `json:"arms"`,
}

// `tag` is the discriminator value that selects this arm, and is what lets a generator emit a
// discriminated union rather than an untagged one. Absent when the arm is chosen from outside the
// payload — never present-but-empty, so a present `tag` is always a real one.
Artifact_Union_Arm :: struct {
    type:      string `json:"type"`,
    tag:       string `json:"tag,omitempty"`,

    // For a union the payload does not tag: whether this arm is written as an omitted member,
    // as null, or as a scalar of `wireType`. A tri-state field cannot be encoded without it.
    form:      string `json:"form,omitempty"`,
    wire_type: string `json:"wireType,omitempty"`,
}

Artifact_Enum :: struct {
    name:    string `json:"name"`,
    doc:     string `json:"doc"`,
    numeric: bool `json:"numeric"`,
    values:  []Artifact_Enum_Value `json:"values"`,
}

Artifact_Enum_Value :: struct {
    name: string `json:"name"`,
    wire: string `json:"wire"`,
    doc:  string `json:"doc"`,
}

Artifact_Alias :: struct {
    name:  string `json:"name"`,
    base:  string `json:"base"`,
    doc:   string `json:"doc"`,
    bound: Maybe(Artifact_Bound) `json:"bound,omitempty"`,
}

// Artifact spelling of an untagged arm's wire form.
@(rodata)
arm_form_json := [Arm_Form]string {
    .None   = "",
    .Absent = "absent",
    .Null   = "null",
    .Value  = "value",
}

// Artifact spelling of a length rule's kind. Written out rather than derived from the enum
// name so the published vocabulary is explicit and greppable.
@(rodata)
bound_kind_json := [Bound_Kind]string {
    .Missing   = "",
    .Bounded   = "bounded",
    .Fixed     = "fixed",
    .Unbounded = "unbounded",
}

// Artifact spelling of a member's absence encoding.
@(rodata)
presence_json := [Presence]string {
    .Required          = "required",
    .Optional          = "optional",
    .Defaulted         = "defaulted",
    .Required_Nullable = "requiredNullable",
    .Tristate          = "tristate",
}

// Project the model onto the published shape. Order is model order throughout — declaration
// order for types, enum order for methods and broadcasts — so the artifact diffs cleanly.
artifact_build :: proc(m: ^Model) -> Artifact {
    assert(m != nil, "artifact_build needs a model")

    out := Artifact {
        protocol_version = m.protocol_version,
        limits           = m.limits,
        constants        = m.consts,
        string_constants = m.strings,
        close_codes      = m.close_codes,
    }

    methods := make([dynamic]Artifact_Method, 0, len(m.methods))

    for method in m.methods {
        append(
            &methods,
            Artifact_Method {
                name = method.wire,
                odin_name = method.name,
                direction = "clientToServer",
                doc = method.doc,
                params = method.params_type,
                result = method.result_type,
                params_optional = method.params_optional,
            },
        )
    }

    out.methods = methods[:]
    broadcasts := make([dynamic]Artifact_Broadcast, 0, len(m.broadcasts))

    for b in m.broadcasts {
        append(
            &broadcasts,
            Artifact_Broadcast {
                name = b.wire,
                odin_name = b.name,
                direction = "serverToClient",
                doc = b.doc,
                params = b.params_type,
                class = b.class,
                seq_field = b.seq_field,
                session_field = b.session_field,
            },
        )
    }

    out.broadcasts = broadcasts[:]
    classes := make([dynamic]Artifact_Delivery_Class, 0, len(m.delivery_classes))

    for c in m.delivery_classes {
        append(
            &classes,
            Artifact_Delivery_Class{name = c.name, gated = c.gated, droppable = c.droppable, sequenced = c.sequenced},
        )
    }

    out.delivery_classes = classes[:]
    errors := make([dynamic]Artifact_Error, 0, len(m.errors))

    for e in m.errors {
        append(&errors, Artifact_Error{odin_name = e.name, code = e.code, doc = e.doc})
    }

    out.errors = errors[:]
    structures := make([dynamic]Artifact_Struct, 0, len(m.structs))

    for s in m.structs {
        fields := make([dynamic]Artifact_Field, 0, len(s.fields))

        for f in s.fields {
            append(
                &fields,
                Artifact_Field {
                    name = f.name,
                    type = f.type_expr,
                    doc = f.doc,
                    presence = presence_json[f.presence],
                    default_expr = f.default_expr,
                    const_expr = f.const_expr,
                    const_value = f.const_value,
                    delivery_role = f.delivery_role,
                    bound = artifact_bound(f.bound),
                },
            )
        }

        append(&structures, Artifact_Struct{name = s.name, doc = s.doc, fields = fields[:]})
    }

    out.structures = structures[:]
    unions := make([dynamic]Artifact_Union, 0, len(m.unions))

    for u in m.unions {
        arms := make([dynamic]Artifact_Union_Arm, 0, len(u.arms))

        for arm in u.arms {
            append(
                &arms,
                Artifact_Union_Arm {
                    type = arm.type,
                    tag = arm.tag,
                    form = arm_form_json[arm.form],
                    wire_type = arm.wire_type,
                },
            )
        }

        append(&unions, Artifact_Union{name = u.name, doc = u.doc, discriminator = u.discriminator, arms = arms[:]})
    }

    out.unions = unions[:]
    enums := make([dynamic]Artifact_Enum, 0, len(m.enums))

    for e in m.enums {
        values := make([dynamic]Artifact_Enum_Value, 0, len(e.values))

        for v in e.values {
            append(&values, Artifact_Enum_Value{name = v.name, wire = v.wire, doc = v.doc})
        }

        append(&enums, Artifact_Enum{name = e.name, doc = e.doc, numeric = e.numeric, values = values[:]})
    }

    out.enumerations = enums[:]
    aliases := make([dynamic]Artifact_Alias, 0, len(m.aliases))

    for a in m.aliases {
        append(&aliases, Artifact_Alias{name = a.name, base = a.base, doc = a.doc, bound = artifact_bound(a.bound)})
    }

    out.aliases = aliases[:]

    return out
}

@(private = "file")
artifact_bound :: proc(b: Bound) -> Maybe(Artifact_Bound) {
    if b.kind == .Missing {
        return nil
    }

    return Artifact_Bound{kind = bound_kind_json[b.kind], expr = b.expr, value = b.value}
}

// Marshal `value` as the committed artifacts are shaped: pretty, two-space, and key-sorted so a
// map's iteration order cannot change the file between runs. One trailing newline.
json_encode :: proc(value: any, allocator := context.allocator) -> (data: []byte, ok: bool) {
    opts := json.Marshal_Options {
        pretty           = true,
        use_spaces       = true,
        spaces           = 2,
        sort_maps_by_key = true,
    }
    bytes, err := json.marshal(value, opts, allocator)

    if err != nil {
        return nil, false
    }

    return transmute([]byte)strings.concatenate({string(bytes), "\n"}, allocator), true
}

// One-line summary of what was written, for the build log.
artifact_report :: proc(a: ^Artifact, path: string, bytes: int) {
    fmt.printfln(
        "%s  %d bytes  %d methods, %d broadcasts, %d structures, %d unions, %d enums, %d aliases",
        path,
        bytes,
        len(a.methods),
        len(a.broadcasts),
        len(a.structures),
        len(a.unions),
        len(a.enumerations),
        len(a.aliases),
    )
}
