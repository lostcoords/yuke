package sqlite

import "base:intrinsics"
import "core:reflect"

// The most parameters one bound struct may carry. Outgrowing this is a design decision,
// not a runtime condition, since a statement is written beside its parameter struct; the
// cap keeps a mapping allocation-free. 32 is the widest statement any caller binds today.
BIND_MAX_PARAMS :: 32

// Why a struct could not be resolved against a statement's parameters. These
// describe the statement/struct pairing, never a bound value: both sides are
// compiled in, so each of these is a programmer error at the site that prepares.
Bind_Error :: enum {
    None,

    // A `sql` tag is malformed, names an unsupported option, or names one that
    // only a scan can honor.
    Invalid_Tag,

    // A source field is not a supported scalar or byte type.
    Unsupported_Type,

    // A source field names no parameter of the statement.
    Parameter_Missing,

    // A statement parameter has no field to bind it.
    Field_Missing,

    // The statement uses a nameless `?` or an ordinal `?NNN` marker.
    Parameter_Unnamed,

    // Two fields name one parameter.
    Parameter_Duplicate,

    // The statement or the struct carries more parameters than a mapping holds.
    Too_Many_Parameters,
}

// A struct shape resolved against one prepared statement's parameters. Owns no
// memory: the slot table is inline, so a mapping is released by dropping it. A
// mapping belongs to its statement and must not outlive it.
Bind_Mapping :: struct($P: typeid) {
    // Statement the mapping resolves parameters against.
    statement: ^Stmt,

    // One entry per flattened source leaf, in parameter order.
    slots:     [BIND_MAX_PARAMS]Bind_Slot,

    // Slots resolved; the rest of the table is unused.
    count:     int,
}

// One resolved leaf: where the value comes from and which parameter it feeds.
@(private)
Bind_Slot :: struct {
    // Source type of the leaf.
    type:   ^reflect.Type_Info,

    // Byte offset from the root of the source struct.
    offset: uintptr,

    // 1-based statement parameter.
    param:  int,
}

// Resolve `P` against `statement`'s named parameters once, rejecting exactly the pairings
// `bind` could not carry out — so a mismatched struct fails here, not on every write. The
// mapping is closed both ways: every field binds one parameter and vice versa. `sql:"name"`
// renames a field, `sql:"-"` ignores it; a scan's `optional`/`borrowed` options are refused.
@(require_results)
bind_prepare :: proc(
    statement: ^Stmt,
    $P: typeid,
) -> (
    mapping: Bind_Mapping(P),
    err: Bind_Error,
) where intrinsics.type_is_struct(P) {
    assert(statement != nil, "bind_prepare needs a statement")

    info := reflect.type_info_base(type_info_of(P))
    assert(info != nil, "a bind source has type information")

    leaves: Bind_Leaves
    bind_walk_error(scan_walk(info, 0, bind_collect_visit, &leaves)) or_return

    if leaves.overflow {
        return {}, .Too_Many_Parameters
    }

    for i in 0 ..< leaves.count {
        leaf := leaves.items[i]

        // Both options describe how a scan takes ownership of SQLite's memory;
        // nothing on this side of the boundary can honor them.
        if leaf.optional || leaf.borrowed {
            return {}, .Invalid_Tag
        }

        matches := 0
        for j in 0 ..< leaves.count {
            if leaves.items[j].name == leaf.name {
                matches += 1
            }
        }

        if matches > 1 {
            return {}, .Parameter_Duplicate
        }
    }

    count := bind_parameter_count(statement)

    if count > BIND_MAX_PARAMS {
        return {}, .Too_Many_Parameters
    }

    // `:a`, `@a`, and `$a` are three parameters that strip to one name, so a leaf
    // can be reached more than once. Counting consumed parameters would call that
    // closed while another field went unbound; only the leaves themselves prove it.
    fed: [BIND_MAX_PARAMS]bool

    mapping.statement = statement
    for index in 1 ..= count {
        name := bind_parameter_name(statement, index)

        // A nameless `?` reports "", and `?NNN` reports its own digits back; both
        // are ordinal markers this mapping has no name to bind them by.
        if len(name) < 2 || (name[0] != ':' && name[0] != '@' && name[0] != '$') {
            return {}, .Parameter_Unnamed
        }

        found := -1
        for i in 0 ..< leaves.count {
            if leaves.items[i].name == name[1:] {
                found = i

                break
            }
        }

        if found < 0 {
            return {}, .Field_Missing
        }

        if fed[found] {
            return {}, .Parameter_Duplicate
        }

        fed[found] = true
        mapping.slots[mapping.count] = Bind_Slot {
            type   = leaves.items[found].type,
            offset = leaves.items[found].offset,
            param  = index,
        }
        mapping.count += 1
    }

    for i in 0 ..< leaves.count {
        if !fed[i] {
            return {}, .Parameter_Missing
        }
    }

    return mapping, .None
}

// Bind every field of `params` to its parameter. SQLite copies text and blobs
// before this returns, so `params` may be a temporary and owns nothing after.
@(require_results)
bind :: proc(mapping: ^Bind_Mapping($P), params: ^P) -> Result where intrinsics.type_is_struct(P) {
    return bind_with_lifetime(mapping, params, .Transient)
}

@(private)
bind_with_lifetime :: proc(
    mapping: ^Bind_Mapping($P),
    params: ^P,
    lifetime: Bind_Lifetime,
) -> Result where intrinsics.type_is_struct(P) {
    assert(mapping != nil, "bind needs a mapping")
    assert(mapping.statement != nil, "a resolved mapping holds its statement")
    assert(params != nil, "bind needs a parameter source")
    assert(mapping.count <= BIND_MAX_PARAMS, "a mapping never resolves past its slot table")

    for i in 0 ..< mapping.count {
        slot := mapping.slots[i]
        assert(slot.param >= 1, "a resolved slot holds a 1-based parameter index")
        assert(slot.type != nil, "a resolved slot holds its source type")

        rc := bind_slot(mapping.statement, slot, rawptr(uintptr(params) + slot.offset), lifetime)

        if rc != .Ok {
            return rc
        }
    }

    return .Ok
}

// Bind `params` and run a statement that yields no rows, leaving it clean for reuse. A
// failed bind resets too, so a partial binding never outlives this call. Text and blobs are
// borrowed through the step and released by the unconditional clear; `.Row` means it wanted `step`.
@(require_results)
execute_bound :: proc(mapping: ^Bind_Mapping($P), params: ^P) -> Result where intrinsics.type_is_struct(P) {
    assert(mapping != nil, "execute needs a mapping")
    assert(mapping.statement != nil, "a resolved mapping holds its statement")

    if rc := bind_with_lifetime(mapping, params, .Statement); rc != .Ok {
        _ = reset_and_clear(mapping.statement)

        return rc
    }

    return execute_stmt(mapping.statement)
}

execute :: proc {
    execute_stmt,
    execute_bound,
}

// The source leaves of one struct, collected before any parameter is consulted.
@(private)
Bind_Leaves :: struct {
    items:    [BIND_MAX_PARAMS]Scan_Leaf,
    count:    int,
    overflow: bool,
}

@(private)
bind_collect_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    leaves := (^Bind_Leaves)(user)

    if leaves.count >= BIND_MAX_PARAMS {
        leaves.overflow = true

        return .None
    }

    leaves.items[leaves.count] = leaf
    leaves.count += 1

    return .None
}

// The field walk is shared with scanning and raises only shape errors both
// directions have; a collecting visitor cannot add any of its own.
@(private)
bind_walk_error :: proc(err: Scan_Error) -> Bind_Error {
    #partial switch err {
    case .None:
        return .None

    case .Invalid_Tag:
        return .Invalid_Tag

    case .Unsupported_Type:
        return .Unsupported_Type
    }

    unreachable()
}

@(private)
bind_slot :: proc(statement: ^Stmt, slot: Bind_Slot, data: rawptr, lifetime: Bind_Lifetime) -> Result {
    assert(statement != nil, "bind_slot needs a statement")
    assert(data != nil, "bind_slot needs source storage")
    assert(slot.type != nil, "bind_slot needs source type information")

    info := reflect.type_info_base(slot.type)

    #partial switch kind in info.variant {
    case reflect.Type_Info_Boolean:
        return bind_i64(statement, slot.param, 1 if bind_bool_load(data, info) else 0)

    case reflect.Type_Info_Integer:
        value, rc := bind_integer_load(data, info)
        if rc != .Ok {
            return rc
        }

        return bind_i64(statement, slot.param, value)

    case reflect.Type_Info_Enum:
        // Enums travel as their discriminant. A type stored as text keeps its own
        // conversion at the call site; the wire name is not the Odin identifier.
        value, rc := bind_integer_load(data, reflect.type_info_base(kind.base))
        if rc != .Ok {
            return rc
        }

        return bind_i64(statement, slot.param, value)

    case reflect.Type_Info_Float:
        return bind_f64(statement, slot.param, bind_float_load(data, info))

    case reflect.Type_Info_String:
        assert(!kind.is_cstring && kind.encoding == .UTF_8, "bind_prepare admits only UTF-8 string sources")

        return bind_text_lifetime(statement, slot.param, (^string)(data)^, lifetime)

    case reflect.Type_Info_Array:
        assert(kind.elem_size == 1, "bind_prepare admits only byte arrays")

        return bind_blob_lifetime(statement, slot.param, ([^]u8)(data)[:info.size], lifetime)

    case reflect.Type_Info_Slice:
        assert(kind.elem_size == 1, "bind_prepare admits only byte slices")

        return bind_blob_lifetime(statement, slot.param, (^[]byte)(data)^, lifetime)

    case reflect.Type_Info_Union:
        // `bind_prepare` admitted this only as a `Maybe(T)`: one variant, nil
        // allowed. Odin stores the payload at offset 0, so the recursion reuses
        // `data` and only swaps the type it is read as.
        assert(len(kind.variants) == 1, "bind_prepare admits only single-variant unions")
        assert(!kind.no_nil, "bind_prepare admits only nil-able unions")

        if !scan_maybe_is_set(data, kind) {
            return bind_null(statement, slot.param)
        }

        return bind_slot(
            statement,
            {type = kind.variants[0], offset = slot.offset, param = slot.param},
            data,
            lifetime,
        )
    }

    // Every other kind was rejected by `scan_type_validate` before a mapping resolved.
    unreachable()
}

@(private)
bind_bool_load :: proc(data: rawptr, info: ^reflect.Type_Info) -> bool {
    assert(data != nil, "bind_bool_load needs source storage")
    assert(info != nil, "bind_bool_load needs type information")

    switch info.size {
    case 1:
        return bool((^b8)(data)^)

    case 2:
        return bool((^b16)(data)^)

    case 4:
        return bool((^b32)(data)^)

    case 8:
        return bool((^b64)(data)^)

    case:
        // `Type_Info_Boolean` has no other widths.
        unreachable()
    }
}

@(private)
bind_integer_load :: proc(data: rawptr, info: ^reflect.Type_Info) -> (value: i64, rc: Result) {
    assert(data != nil, "bind_integer_load needs source storage")
    assert(info != nil, "bind_integer_load needs type information")

    integer, is_integer := info.variant.(reflect.Type_Info_Integer)
    assert(is_integer, "bind_integer_load receives an integer source")
    assert(integer.endianness == .Platform, "scan_type_validate rejects byte-order-specific integers")

    if integer.signed {
        switch info.size {
        case 1:
            return i64((^i8)(data)^), .Ok

        case 2:
            return i64((^i16)(data)^), .Ok

        case 4:
            return i64((^i32)(data)^), .Ok

        case 8:
            return (^i64)(data)^, .Ok

        case:
            unreachable()
        }
    }

    switch info.size {
    case 1:
        return i64((^u8)(data)^), .Ok

    case 2:
        return i64((^u16)(data)^), .Ok

    case 4:
        return i64((^u32)(data)^), .Ok

    case 8:
        value := (^u64)(data)^
        if value > u64(max(i64)) {
            return 0, .Range
        }

        return i64(value), .Ok

    case:
        // `scan_type_validate` admits only the four widths above.
        unreachable()
    }
}

@(private)
bind_float_load :: proc(data: rawptr, info: ^reflect.Type_Info) -> f64 {
    assert(data != nil, "bind_float_load needs source storage")
    assert(info != nil, "bind_float_load needs type information")

    float, is_float := info.variant.(reflect.Type_Info_Float)
    assert(is_float, "bind_float_load receives a float source")
    assert(float.endianness == .Platform, "scan_type_validate rejects byte-order-specific floats")

    switch info.size {
    case 2:
        return f64((^f16)(data)^)

    case 4:
        return f64((^f32)(data)^)

    case 8:
        return (^f64)(data)^

    case:
        // `scan_type_validate` admits only the three platform-endian widths above.
        unreachable()
    }
}
