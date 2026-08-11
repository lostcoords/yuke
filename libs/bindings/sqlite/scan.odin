package sqlite

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:strings"

// Why a current SQLite row could not be materialized into its destination.
// These describe query/result shape and persisted values, not SQLite execution;
// the caller still owns `step`, `reset`, and their `Result` values.
Scan_Error :: enum {
    None,

    // A `sql` tag is malformed or names an unsupported option.
    Invalid_Tag,

    // A non-ignored destination field is not a supported scalar or byte type.
    Unsupported_Type,

    // A mandatory destination field has no result column.
    Column_Missing,

    // A result column has no destination field.
    Column_Unknown,

    // Columns or fields do not form a one-to-one name mapping.
    Column_Duplicate,

    // The SQLite storage class does not exactly match the destination kind.
    Storage_Type_Mismatch,

    // SQL NULL cannot populate a non-nullable destination field.
    Null_Not_Allowed,

    // An integer, enum, float, or fixed blob cannot fit its destination.
    Value_Out_Of_Range,

    // Cloning owned text or blob data failed.
    Out_Of_Memory,
}

// Materialize the current `.Row` into `value`. Text and byte slices clone into `allocator`;
// release with `scan_destroy`. Untagged fields are mandatory by name; `sql:"name,optional"`
// allows a missing column and `sql:"-"` skips a field. SQL NULL errors except into a
// `Maybe(T)` (nil variant); `sql:"name,borrowed"` borrows SQLite's memory instead, which must not outlive the row.
@(require_results)
scan_row :: proc(
    statement: ^Stmt,
    value: ^$T,
    allocator := context.allocator,
) -> (
    err: Scan_Error,
) where intrinsics.type_is_struct(T) {
    assert(statement != nil, "scan_row needs a statement on a row")
    assert(value != nil, "scan_row needs destination storage")
    assert(allocator.procedure != nil, "scan_row needs an allocator")

    info := reflect.type_info_base(type_info_of(T))
    assert(info != nil, "a scan destination has type information")

    if shape_err := scan_shape(statement, info); shape_err != .None {
        return shape_err
    }

    assert(scan_value_owns_nothing(rawptr(value), info), "scan destination must own nothing")
    scan_value_clear(rawptr(value), info)

    store := Scan_Store {
        statement = statement,
        data      = rawptr(value),
        allocator = allocator,
    }
    err = scan_walk(info, 0, scan_store_visit, &store)

    if err != .None {
        scan_value_destroy(rawptr(value), info, allocator)
        scan_value_clear(rawptr(value), info)

        return
    }

    return
}

// A destination shape resolved against one prepared statement. `scan_prepare` records
// the column each leaf binds to, so scanning a row is a straight store loop — no tag
// parsing, no reflection, no column search. Release it before the statement is finalized.
Scan_Mapping :: struct($T: typeid) {
    // Statement the mapping resolves columns against.
    statement: ^Stmt,

    // One entry per flattened destination leaf, in declaration order.
    binds:     []Scan_Bind,
}

// One resolved leaf: where the value goes and which column it comes from.
@(private)
Scan_Bind :: struct {
    // Destination type of the leaf.
    type:     ^reflect.Type_Info,

    // Byte offset from the root of the destination struct.
    offset:   uintptr,

    // Result column, or -1 for an optional field this result set omits.
    col:      int,

    // The field points into SQLite's column memory instead of owning a clone.
    borrowed: bool,
}

// Resolve `T` against `statement` once. This rejects exactly the shapes `scan_row`
// rejects, so a destination that does not match the query fails here rather than on
// every row. Release with `scan_mapping_destroy`.
@(require_results)
scan_prepare :: proc(
    statement: ^Stmt,
    $T: typeid,
    allocator := context.allocator,
) -> (
    mapping: Scan_Mapping(T),
    err: Scan_Error,
) where intrinsics.type_is_struct(T) {
    assert(statement != nil, "scan_prepare needs a statement")
    assert(allocator.procedure != nil, "scan_prepare needs an allocator")

    info := reflect.type_info_base(type_info_of(T))
    assert(info != nil, "a scan destination has type information")

    scan_shape(statement, info) or_return

    // The leaf count is a property of the destination type, but flattening `using`
    // makes it a runtime one; counting first keeps the mapping a single exact allocation.
    count := 0
    tally_err := scan_walk(info, 0, scan_tally_visit, &count)
    assert(tally_err == .None, "a validated shape walks without error")

    binds, make_err := make([]Scan_Bind, count, allocator)

    if make_err != nil {
        return {}, .Out_Of_Memory
    }

    fill := Scan_Fill {
        statement = statement,
        binds     = binds,
    }
    fill_err := scan_walk(info, 0, scan_fill_visit, &fill)
    assert(fill_err == .None, "a validated shape walks without error")
    assert(fill.filled == count, "the mapping binds every leaf exactly once")

    return Scan_Mapping(T){statement = statement, binds = binds}, .None
}

// Release a mapping's bindings and blank it. `allocator` must be the one supplied to
// `scan_prepare`.
scan_mapping_destroy :: proc(mapping: ^Scan_Mapping($T), allocator := context.allocator) {
    assert(mapping != nil, "scan_mapping_destroy needs a mapping")

    delete(mapping.binds, allocator)
    mapping^ = {}
}

// Materialize the current `.Row` into `value` through an already-resolved mapping.
// Ownership matches `scan_row`: clones live in `allocator` and are released with
// `scan_destroy`, and every scanned field is left zeroed on failure.
@(require_results)
scan :: proc(
    mapping: ^Scan_Mapping($T),
    value: ^T,
    allocator := context.allocator,
) -> Scan_Error where intrinsics.type_is_struct(T) {
    assert(mapping != nil, "scan needs a mapping")
    assert(mapping.statement != nil, "scan needs a prepared mapping")
    assert(value != nil, "scan needs destination storage")
    assert(allocator.procedure != nil, "scan needs an allocator")

    info := reflect.type_info_base(type_info_of(T))
    assert(info != nil, "a scan destination has type information")
    assert(scan_value_owns_nothing(rawptr(value), info), "scan destination must own nothing")

    scan_value_clear(rawptr(value), info)
    for bind in mapping.binds {
        if bind.col < 0 {
            continue
        }

        destination := any{rawptr(uintptr(value) + bind.offset), bind.type.id}
        column_err := scan_column(mapping.statement, bind.col, destination, bind.borrowed, allocator)

        if column_err != .None {
            scan_value_destroy(rawptr(value), info, allocator)
            scan_value_clear(rawptr(value), info)

            return column_err
        }
    }

    return .None
}

// Release every owned text or byte slice in a successfully scanned struct and
// zero every scanned field. Ignored fields are untouched. `allocator` must be
// the one supplied to `scan_row`.
scan_destroy :: proc(value: ^$T, allocator := context.allocator) where intrinsics.type_is_struct(T) {
    assert(value != nil, "scan_destroy needs a value")
    assert(allocator.procedure != nil, "scan_destroy needs an allocator")

    info := reflect.type_info_base(type_info_of(T))
    assert(info != nil, "a scan destination has type information")

    scan_value_destroy(rawptr(value), info, allocator)
    scan_value_clear(rawptr(value), info)
}

@(private)
Scan_Tag :: struct {
    name:     string,
    optional: bool,
    borrowed: bool,
    ignored:  bool,
    explicit: bool,
}

@(private)
scan_tag :: proc(field: reflect.Struct_Field) -> (tag: Scan_Tag, err: Scan_Error) {
    tag.name = field.name

    value, explicit := reflect.struct_tag_lookup(field.tag, "sql")

    if !explicit {
        return tag, .None
    }

    tag.explicit = true
    comma := strings.index_byte(value, ',')
    options := ""

    if comma >= 0 {
        tag.name = value[:comma]
        options = value[comma + 1:]

        if options == "" {
            return {}, .Invalid_Tag
        }
    } else {
        tag.name = value
    }

    if tag.name == "" {
        tag.name = field.name
    }

    if tag.name == "-" {
        if options != "" {
            return {}, .Invalid_Tag
        }

        tag.ignored = true

        return tag, .None
    }

    if options == "" {
        return tag, .None
    }

    for option in strings.split_iterator(&options, ",") {
        switch option {
        case "optional":
            if tag.optional {
                return {}, .Invalid_Tag
            }

            tag.optional = true

        case "borrowed":
            if tag.borrowed {
                return {}, .Invalid_Tag
            }

            tag.borrowed = true

        case:
            return {}, .Invalid_Tag
        }
    }

    return tag, .None
}

// One scanned field, after `using` embedding is flattened away. Ignored fields and
// the embedded structs themselves are containers, not leaves; a leaf is exactly the
// unit a result column binds to and the unit a scan can own memory for.
@(private)
Scan_Leaf :: struct {
    // Result column this field binds to.
    name:     string,

    // Destination type, already accepted by `scan_type_validate`.
    type:     ^reflect.Type_Info,

    // Byte offset from the root struct, summed through every `using` level.
    offset:   uintptr,

    // A missing result column leaves this field zeroed instead of failing.
    optional: bool,

    // The field points into SQLite's column memory instead of owning a clone.
    borrowed: bool,
}

@(private)
Scan_Visitor :: #type proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error

// The single definition of which fields a scan reads and owns. Shape validation,
// storing a row, and releasing a scanned value all walk here, so the tag ladder and
// the accepted type surface exist once and cannot drift apart. Both directions accept
// the same types, so the walk is direction-free.
@(private)
scan_walk :: proc(info: ^reflect.Type_Info, offset: uintptr, visit: Scan_Visitor, user: rawptr) -> Scan_Error {
    assert(info != nil, "scan_walk needs type information")
    assert(visit != nil, "scan_walk needs a visitor")

    base := reflect.type_info_base(info)
    struct_info, is_struct := base.variant.(reflect.Type_Info_Struct)

    if !is_struct || .raw_union in struct_info.flags {
        return .Unsupported_Type
    }

    for field in reflect.struct_fields_zipped(base.id) {
        tag := scan_tag(field) or_return

        if tag.ignored {
            continue
        }

        if field.is_using {
            // An embedded struct contributes columns; it is never one itself, so a
            // name on it would be ambiguous with the leaves underneath.
            if tag.explicit {
                return .Invalid_Tag
            }

            scan_walk(field.type, offset + field.offset, visit, user) or_return

            continue
        }

        scan_type_validate(field.type) or_return

        // Borrowing is only meaningful where a clone would otherwise be made; on a
        // by-value destination it would silently mean nothing.
        if tag.borrowed && !scan_type_owns(field.type) {
            return .Invalid_Tag
        }

        leaf := Scan_Leaf {
            name     = tag.name,
            type     = field.type,
            offset   = offset + field.offset,
            optional = tag.optional,
            borrowed = tag.borrowed,
        }

        visit(user, leaf) or_return
    }

    return .None
}

// Validate the closed column/field mapping before cloning any row data.
@(private)
scan_shape :: proc(statement: ^Stmt, info: ^reflect.Type_Info) -> Scan_Error {
    assert(statement != nil, "scan_shape needs a statement")
    assert(info != nil, "scan_shape needs destination type information")

    scan_walk(info, 0, scan_unique_visit, rawptr(info)) or_return

    for col in 0 ..< column_count(statement) {
        matches := scan_leaf_count(info, column_name(statement, col)) or_return

        if matches == 0 {
            return .Column_Unknown
        }

        if matches > 1 {
            return .Column_Duplicate
        }
    }

    return scan_walk(info, 0, scan_required_visit, rawptr(statement))
}

// Reject a destination that binds two fields to one column name; `user` is the root
// type the walk started from.
@(private)
scan_unique_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    root := (^reflect.Type_Info)(user)
    matches := scan_leaf_count(root, leaf.name) or_return

    return .Column_Duplicate if matches > 1 else .None
}

// Reject a mandatory field the result set has no column for, and an ambiguous column
// name; `user` is the statement being scanned.
@(private)
scan_required_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    statement := (^Stmt)(user)
    matches := 0

    for col in 0 ..< column_count(statement) {
        if column_name(statement, col) == leaf.name {
            matches += 1
        }
    }

    if matches > 1 {
        return .Column_Duplicate
    }

    return .Column_Missing if matches == 0 && !leaf.optional else .None
}

@(private)
Scan_Leaf_Count :: struct {
    name:    string,
    matches: int,
}

@(private)
scan_count_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    counter := (^Scan_Leaf_Count)(user)

    if leaf.name == counter.name {
        counter.matches += 1
    }

    return .None
}

// Whether a validated leaf type is one a scan clones into the caller's allocator.
// Every other accepted type is stored by value and owns nothing.
@(private)
scan_type_owns :: proc(info: ^reflect.Type_Info) -> bool {
    assert(info != nil, "scan_type_owns needs type information")

    #partial switch kind in reflect.type_info_base(info).variant {
    case reflect.Type_Info_String:
        return true

    case reflect.Type_Info_Slice:
        return true

    case reflect.Type_Info_Union:
        assert(len(kind.variants) == 1 && !kind.no_nil, "the walk admits only Maybe leaves")
        return scan_type_owns(kind.variants[0])
    }

    return false
}

// How many leaves of `root` bind to `name`.
@(private)
scan_leaf_count :: proc(root: ^reflect.Type_Info, name: string) -> (matches: int, err: Scan_Error) {
    assert(root != nil, "scan_leaf_count needs type information")

    counter := Scan_Leaf_Count {
        name = name,
    }
    scan_walk(root, 0, scan_count_visit, &counter) or_return

    return counter.matches, .None
}

@(private)
scan_column_find :: proc(statement: ^Stmt, name: string) -> int {
    assert(statement != nil, "scan_column_find needs a statement")

    for col in 0 ..< column_count(statement) {
        if column_name(statement, col) == name {
            return col
        }
    }

    return -1
}

@(private)
scan_type_validate :: proc(info: ^reflect.Type_Info) -> Scan_Error {
    assert(info != nil, "scan_type_validate needs type information")

    base := reflect.type_info_base(info)

    #partial switch kind in base.variant {
    case reflect.Type_Info_Boolean:
        return .None

    case reflect.Type_Info_Integer:
        if kind.endianness != .Platform || (base.size != 1 && base.size != 2 && base.size != 4 && base.size != 8) {
            return .Unsupported_Type
        }

        return .None

    case reflect.Type_Info_Enum:
        return scan_type_validate(kind.base)

    case reflect.Type_Info_Union:
        // Only `Maybe(T)`: one variant, nil admitted, payload itself supported. NULL binds
        // from the nil variant and scans back into it, so the two directions are inverses.
        if len(kind.variants) != 1 || kind.no_nil {
            return .Unsupported_Type
        }

        return scan_type_validate(kind.variants[0])

    case reflect.Type_Info_Float:
        if kind.endianness != .Platform || (base.size != 2 && base.size != 4 && base.size != 8) {
            return .Unsupported_Type
        }

        return .None

    case reflect.Type_Info_String:
        return .None if !kind.is_cstring && kind.encoding == .UTF_8 else .Unsupported_Type

    case reflect.Type_Info_Array:
        elem := reflect.type_info_base(kind.elem)

        return .None if elem.id == typeid_of(u8) && kind.elem_size == 1 else .Unsupported_Type

    case reflect.Type_Info_Slice:
        elem := reflect.type_info_base(kind.elem)

        return .None if elem.id == typeid_of(u8) && kind.elem_size == 1 else .Unsupported_Type
    }

    return .Unsupported_Type
}

@(private)
scan_tally_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    count := (^int)(user)
    count^ += 1

    return .None
}

@(private)
Scan_Fill :: struct {
    statement: ^Stmt,
    binds:     []Scan_Bind,
    filled:    int,
}

@(private)
scan_fill_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    fill := (^Scan_Fill)(user)
    assert(fill.filled < len(fill.binds), "the tally pass counted every leaf")

    col := scan_column_find(fill.statement, leaf.name)
    assert(col >= 0 || leaf.optional, "scan_shape admits only absent optional fields")

    fill.binds[fill.filled] = Scan_Bind {
        type     = leaf.type,
        offset   = leaf.offset,
        col      = col,
        borrowed = leaf.borrowed,
    }
    fill.filled += 1

    return .None
}

@(private)
Scan_Store :: struct {
    statement: ^Stmt,
    data:      rawptr,
    allocator: mem.Allocator,
}

// Materialize one leaf out of the current row. Runs only behind `scan_shape`, so an
// unresolved column here is an optional field the result set omits.
@(private)
scan_store_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    store := (^Scan_Store)(user)
    col := scan_column_find(store.statement, leaf.name)

    if col < 0 {
        assert(leaf.optional, "scan_shape admits only absent optional fields")

        return .None
    }

    destination := any{rawptr(uintptr(store.data) + leaf.offset), leaf.type.id}

    return scan_column(store.statement, col, destination, leaf.borrowed, store.allocator)
}

@(private)
scan_column :: proc(
    statement: ^Stmt,
    col: int,
    destination: any,
    borrowed: bool,
    allocator: mem.Allocator,
) -> Scan_Error {
    assert(statement != nil, "scan_column needs a statement")
    assert(col >= 0, "scan_column needs a non-negative column")
    assert(col < column_count(statement), "scan_column needs an in-range column")
    assert(destination != nil, "scan_column needs destination storage")

    storage := column_type(statement, col)
    info := reflect.type_info_base(type_info_of(destination.id))

    // `Maybe(T)`: NULL is the nil variant rather than an error. Odin stores the payload at
    // offset 0, reusing `destination.data`; a nil variant needs no write, since the caller already zeroed it.
    if maybe_info, is_maybe := info.variant.(reflect.Type_Info_Union); is_maybe {
        assert(len(maybe_info.variants) == 1 && !maybe_info.no_nil, "the walk admits only Maybe destinations")
        assert(maybe_info.tag_type != nil, "scan_type_validate rejects the pointer payloads that erase the tag")

        if storage == .Null {
            return .None
        }

        scan_column(statement, col, any{destination.data, maybe_info.variants[0].id}, borrowed, allocator) or_return

        return scan_integer_store(
            rawptr(uintptr(destination.data) + maybe_info.tag_offset),
            reflect.type_info_base(maybe_info.tag_type),
            1,
        )
    }

    if storage == .Null {
        return .Null_Not_Allowed
    }

    #partial switch kind in info.variant {
    case reflect.Type_Info_Boolean:
        if storage != .Integer {
            return .Storage_Type_Mismatch
        }

        value := column_i64(statement, col)

        if value != 0 && value != 1 {
            return .Value_Out_Of_Range
        }

        return scan_bool_store(destination, value == 1)

    case reflect.Type_Info_Integer:
        if storage != .Integer {
            return .Storage_Type_Mismatch
        }

        return scan_integer_store(destination.data, info, column_i64(statement, col))

    case reflect.Type_Info_Enum:
        if storage != .Integer {
            return .Storage_Type_Mismatch
        }

        value := column_i64(statement, col)
        known := false
        for candidate in kind.values {
            if i64(candidate) == value {
                known = true
                break
            }
        }

        if !known {
            return .Value_Out_Of_Range
        }

        return scan_integer_store(destination.data, reflect.type_info_base(kind.base), value)

    case reflect.Type_Info_Float:
        if storage != .Float {
            return .Storage_Type_Mismatch
        }

        return scan_float_store(destination, column_f64(statement, col))

    case reflect.Type_Info_String:
        if storage != .Text {
            return .Storage_Type_Mismatch
        }

        assert(!kind.is_cstring && kind.encoding == .UTF_8, "scan_shape admits only UTF-8 string destinations")

        source, rc := column_text(statement, col)
        if rc != .Ok {
            assert(rc == .No_Mem, "column_text reports only conversion OOM")

            return .Out_Of_Memory
        }

        if borrowed {
            (^string)(destination.data)^ = source

            return .None
        }

        cloned, clone_err := strings.clone(source, allocator)

        if clone_err != nil {
            return .Out_Of_Memory
        }

        (^string)(destination.data)^ = cloned

        return .None

    case reflect.Type_Info_Array:
        if storage != .Blob {
            return .Storage_Type_Mismatch
        }

        elem := reflect.type_info_base(kind.elem)
        assert(elem.id == typeid_of(u8) && kind.elem_size == 1, "scan_shape admits only byte arrays")

        source := column_blob(statement, col)

        if len(source) != kind.count {
            return .Value_Out_Of_Range
        }

        if len(source) > 0 {
            mem.copy(destination.data, raw_data(source), len(source))
        }

        return .None

    case reflect.Type_Info_Slice:
        if storage != .Blob {
            return .Storage_Type_Mismatch
        }

        elem := reflect.type_info_base(kind.elem)
        assert(elem.id == typeid_of(u8) && kind.elem_size == 1, "scan_shape admits only byte slices")

        source := column_blob(statement, col)

        if borrowed {
            (^[]byte)(destination.data)^ = source

            return .None
        }

        cloned, clone_err := make([]byte, len(source), allocator)

        if clone_err != nil {
            return .Out_Of_Memory
        }

        copy(cloned, source)
        (^[]byte)(destination.data)^ = cloned

        return .None
    }

    // Every other kind was rejected by `scan_type_validate` before a row was touched.
    unreachable()
}

@(private)
scan_bool_store :: proc(destination: any, value: bool) -> Scan_Error {
    core := reflect.any_core(destination)

    switch &out in core {
    case bool:
        out = value

    case b8:
        out = b8(value)

    case b16:
        out = b16(value)

    case b32:
        out = b32(value)

    case b64:
        out = b64(value)

    case:
        // `Type_Info_Boolean` has no other members and no endian variants.
        unreachable()
    }

    return .None
}

@(private)
scan_integer_store :: proc(data: rawptr, info: ^reflect.Type_Info, value: i64) -> Scan_Error {
    assert(data != nil, "scan_integer_store needs destination storage")
    assert(info != nil, "scan_integer_store needs destination type information")

    integer, is_integer := info.variant.(reflect.Type_Info_Integer)
    assert(is_integer, "scan_integer_store receives an integer destination")

    assert(integer.endianness == .Platform, "scan_type_validate rejects byte-order-specific integers")

    if integer.signed {
        switch info.size {
        case 1:
            if value < -128 || value > 127 {
                return .Value_Out_Of_Range
            }
            (^i8)(data)^ = i8(value)

        case 2:
            if value < -32768 || value > 32767 {
                return .Value_Out_Of_Range
            }
            (^i16)(data)^ = i16(value)

        case 4:
            if value < -2147483648 || value > 2147483647 {
                return .Value_Out_Of_Range
            }
            (^i32)(data)^ = i32(value)

        case 8:
            (^i64)(data)^ = value

        case:
            unreachable()
        }

        return .None
    }

    if value < 0 {
        return .Value_Out_Of_Range
    }

    unsigned := u64(value)

    switch info.size {
    case 1:
        if unsigned > 255 {
            return .Value_Out_Of_Range
        }
        (^u8)(data)^ = u8(unsigned)

    case 2:
        if unsigned > 65535 {
            return .Value_Out_Of_Range
        }
        (^u16)(data)^ = u16(unsigned)

    case 4:
        if unsigned > 4294967295 {
            return .Value_Out_Of_Range
        }
        (^u32)(data)^ = u32(unsigned)

    case 8:
        (^u64)(data)^ = unsigned

    case:
        // `scan_type_validate` admits only the four widths above.
        unreachable()
    }

    return .None
}

@(private)
scan_float_store :: proc(destination: any, value: f64) -> Scan_Error {
    core := reflect.any_core(destination)

    switch &out in core {
    case f16:
        converted := f16(value)

        if math.is_inf(converted) && !math.is_inf(value) {
            return .Value_Out_Of_Range
        }

        out = converted

    case f32:
        converted := f32(value)

        if math.is_inf(converted) && !math.is_inf(value) {
            return .Value_Out_Of_Range
        }

        out = converted

    case f64:
        out = value

    case:
        // `scan_type_validate` admits only the three platform-endian widths above.
        unreachable()
    }

    return .None
}

@(private)
Scan_Release :: struct {
    data:      rawptr,
    allocator: mem.Allocator,
}

@(private)
Scan_Empty :: struct {
    data:  rawptr,
    empty: bool,
}

@(private)
scan_empty_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    state := (^Scan_Empty)(user)
    state.empty &= scan_leaf_owns_nothing(rawptr(uintptr(state.data) + leaf.offset), leaf.type)

    return .None
}

@(private)
scan_leaf_owns_nothing :: proc(data: rawptr, type: ^reflect.Type_Info) -> bool {
    assert(data != nil, "scan_leaf_owns_nothing needs leaf storage")
    assert(type != nil, "scan_leaf_owns_nothing needs leaf type information")

    #partial switch kind in reflect.type_info_base(type).variant {
    case reflect.Type_Info_String:
        _ = kind

        return (^string)(data)^ == ""

    case reflect.Type_Info_Slice:
        _ = kind

        return (^[]byte)(data)^ == nil

    case reflect.Type_Info_Union:
        // A set `Maybe(T)` owns exactly what its payload owns, at offset 0.
        assert(len(kind.variants) == 1 && kind.tag_type != nil, "the walk admits only Maybe leaves")

        return !scan_maybe_is_set(data, kind) || scan_leaf_owns_nothing(data, kind.variants[0])
    }

    return true
}

@(private)
scan_value_owns_nothing :: proc(data: rawptr, info: ^reflect.Type_Info) -> bool {
    assert(data != nil, "scan_value_owns_nothing needs value storage")
    assert(info != nil, "scan_value_owns_nothing needs type information")

    state := Scan_Empty {
        data  = data,
        empty = true,
    }
    err := scan_walk(info, 0, scan_empty_visit, &state)
    assert(err == .None, "a successfully shaped scan walks without error")

    return state.empty
}

@(private)
scan_clear_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    data := rawptr(uintptr(user) + leaf.offset)
    info := reflect.type_info_base(leaf.type)
    mem.zero(data, info.size)

    return .None
}

@(private)
scan_value_clear :: proc(data: rawptr, info: ^reflect.Type_Info) {
    assert(data != nil, "scan_value_clear needs value storage")
    assert(info != nil, "scan_value_clear needs type information")

    err := scan_walk(info, 0, scan_clear_visit, data)
    assert(err == .None, "a successfully shaped scan walks without error")
}

@(private)
scan_release_visit :: proc(user: rawptr, leaf: Scan_Leaf) -> Scan_Error {
    release := (^Scan_Release)(user)
    scan_leaf_release(rawptr(uintptr(release.data) + leaf.offset), leaf.type, leaf.borrowed, release.allocator)

    return .None
}

// Only text and byte slices are cloned; everything else is stored by value and owns nothing.
// A borrowed leaf points into SQLite's memory, so it is blanked rather than freed.
@(private)
scan_leaf_release :: proc(data: rawptr, type: ^reflect.Type_Info, borrowed: bool, allocator: mem.Allocator) {
    assert(data != nil, "scan_leaf_release needs leaf storage")
    assert(type != nil, "scan_leaf_release needs leaf type information")

    base := reflect.type_info_base(type)

    #partial switch kind in base.variant {
    case reflect.Type_Info_String:
        assert(!kind.is_cstring && kind.encoding == .UTF_8, "the walk admits only UTF-8 string leaves")

        if !borrowed {
            delete((^string)(data)^, allocator)
        }

        (^string)(data)^ = ""

    case reflect.Type_Info_Slice:
        assert(kind.elem_size == 1, "the walk admits only byte slice leaves")

        if !borrowed {
            delete((^[]byte)(data)^, allocator)
        }

        (^[]byte)(data)^ = nil

    case reflect.Type_Info_Union:
        // A nil `Maybe(T)` owns nothing; a set one owns whatever its payload does, at
        // offset 0. Zeroing covers the payload and the tag in one step.
        assert(len(kind.variants) == 1 && kind.tag_type != nil, "the walk admits only Maybe leaves")

        if scan_maybe_is_set(data, kind) {
            scan_leaf_release(data, kind.variants[0], borrowed, allocator)
            mem.zero(data, base.size)
        }
    }
}

// Whether a `Maybe(T)` holds its payload. The tag is the only discriminator, so a
// caller that reads the payload without it would see a stale value from a failed scan.
@(private)
scan_maybe_is_set :: proc(data: rawptr, info: reflect.Type_Info_Union) -> bool {
    assert(data != nil, "scan_maybe_is_set needs union storage")
    assert(info.tag_type != nil, "scan_type_validate rejects the pointer payloads that erase the tag")

    tag, rc := bind_integer_load(rawptr(uintptr(data) + info.tag_offset), reflect.type_info_base(info.tag_type))
    assert(rc == .Ok, "a union tag is an integer this package wrote")
    assert(tag == 0 || tag == 1, "a single-variant union tag is nil or its only variant")

    return tag == 1
}

@(private)
scan_value_destroy :: proc(data: rawptr, info: ^reflect.Type_Info, allocator: mem.Allocator) {
    assert(data != nil, "scan_value_destroy needs value storage")
    assert(info != nil, "scan_value_destroy needs type information")

    release := Scan_Release {
        data      = data,
        allocator = allocator,
    }
    err := scan_walk(info, 0, scan_release_visit, &release)
    assert(err == .None, "a successfully shaped scan walks without error")
}
