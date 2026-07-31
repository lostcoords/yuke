package quickjs

import "core:c"

// Opaque engine instance (`JSRuntime *`).
Runtime :: struct {}

// Opaque execution environment (`JSContext *`).
Context :: struct {}

// Interned property name (`JSAtom`).
Atom :: distinct u32

// `JS_ATOM_NULL`: what interning a name returns when it fails.
ATOM_NULL :: Atom(0)

// Registered class id (`JSClassID`).
Class_ID :: distinct u32

INVALID_CLASS_ID :: Class_ID(0)

// Opaque compiled module handle (`JSModuleDef *`).
Module_Def :: struct {}

// Opaque GC node header (`JSGCObjectHeader`).
GC_Object_Header :: struct {}

// Tag discriminating the payload in `Value.u`. Negative tags are reference
// counted.
Tag :: enum i64 {
    Big_Int           = -9,
    Symbol            = -8,
    String            = -7,
    String_Rope       = -6,
    Module            = -3,
    Function_Bytecode = -2,
    Object            = -1,
    Int               = 0,
    Bool              = 1,
    Null              = 2,
    Undefined         = 3,
    Uninitialized     = 4,
    Catch_Offset      = 5,
    Exception         = 6,
    Short_Big_Int     = 7,
    Float64           = 8,
}

Value_Union :: struct #raw_union {
    int32:         i32,
    float64:       f64,
    ptr:           rawptr,
    short_big_int: i32,
}

// A JavaScript value (`JSValue`), passed and returned **by value** across the
// FFI. Reference-counted arms (negative `tag`) must be released with
// `free_value` exactly once.
Value :: struct {
    u:   Value_Union,
    tag: Tag,
}

// ABI: a mismatch means the archive was built with different flags (NaN
// boxing, 32-bit) and every call would silently corrupt memory.
#assert(size_of(Value) == 16)
#assert(offset_of(Value, tag) == 8)

// Per-runtime allocator hooks (`JSMallocFunctions`).
Alloc_Functions :: struct {
    calloc:      proc "c" (user: rawptr, count, size: c.size_t) -> rawptr,
    malloc:      proc "c" (user: rawptr, size: c.size_t) -> rawptr,
    free:        proc "c" (user: rawptr, ptr: rawptr),
    realloc:     proc "c" (user: rawptr, ptr: rawptr, size: c.size_t) -> rawptr,
    usable_size: proc "c" (ptr: rawptr) -> c.size_t,
}

#assert(size_of(Alloc_Functions) == 40)

// Engine memory accounting (`JSMemoryUsage`).
Memory_Usage :: struct {
    malloc_size, malloc_limit, memory_used_size:    i64,
    malloc_count:                                   i64,
    memory_used_count:                              i64,
    atom_count, atom_size:                          i64,
    str_count, str_size:                            i64,
    obj_count, obj_size:                            i64,
    prop_count, prop_size:                          i64,
    shape_count, shape_size:                        i64,
    js_func_count, js_func_size, js_func_code_size: i64,
    js_func_pc2line_count, js_func_pc2line_size:    i64,
    c_func_count, array_count:                      i64,
    fast_array_count, fast_array_elements:          i64,
    binary_object_count, binary_object_size:        i64,
}

#assert(size_of(Memory_Usage) == 208)

// A host procedure callable from JavaScript. `argv` is borrowed for the call.
C_Function :: proc "c" (ctx: ^Context, this_val: Value, argc: c.int, argv: [^]Value) -> Value

// Like `C_Function` but carries the `magic` value it was registered with.
C_Function_Magic :: proc "c" (ctx: ^Context, this_val: Value, argc: c.int, argv: [^]Value, magic: c.int) -> Value

// A host procedure closing over `func_data`.
C_Function_Data :: proc "c" (
    ctx: ^Context,
    this_val: Value,
    argc: c.int,
    argv: [^]Value,
    magic: c.int,
    func_data: [^]Value,
) -> Value

// A host procedure closing over a raw `opaque` pointer.
C_Closure :: proc "c" (
    ctx: ^Context,
    this_val: Value,
    argc: c.int,
    argv: [^]Value,
    magic: c.int,
    opaque: rawptr,
) -> Value

// Runs when a `C_Closure`'s owning function object is finalized, to release
// `opaque`.
C_Closure_Finalizer_Func :: proc "c" (opaque: rawptr)

// Called periodically while JS runs; return non-zero to abort the script.
Interrupt_Handler :: proc "c" (rt: ^Runtime, user: rawptr) -> c.int

// Runs in LIFO order during `JS_FreeRuntime`.
Runtime_Finalizer :: proc "c" (rt: ^Runtime, arg: rawptr)

// GC marking callback passed to `JS_MarkValue` and `Class_GC_Mark`.
Mark_Func :: proc "c" (rt: ^Runtime, gp: ^GC_Object_Header)

// Calling convention for a host procedure; `.Generic` matches `C_Function`.
C_Function_Kind :: enum c.int {
    Generic,
    Generic_Magic,
    Constructor,
    Constructor_Magic,
    Constructor_Or_Func,
    Constructor_Or_Func_Magic,
    F_F,
    F_F_F,
    Getter,
    Setter,
    Getter_Magic,
    Setter_Magic,
    Iterator_Next,
}

// Union of every callback shape a `C_Function_List_Entry` can carry
// (`JSCFunctionType`).
C_Function_Type :: struct #raw_union {
    generic:             C_Function,
    generic_magic:       C_Function_Magic,
    constructor:         C_Function,
    constructor_magic:   proc "c" (
        ctx: ^Context,
        new_target: Value,
        argc: c.int,
        argv: [^]Value,
        magic: c.int,
    ) -> Value,
    constructor_or_func: C_Function,
    f_f:                 proc "c" (_: f64) -> f64,
    f_f_f:               proc "c" (_: f64, _: f64) -> f64,
    getter:              proc "c" (ctx: ^Context, this_val: Value) -> Value,
    setter:              proc "c" (ctx: ^Context, this_val: Value, val: Value) -> Value,
    getter_magic:        proc "c" (ctx: ^Context, this_val: Value, magic: c.int) -> Value,
    setter_magic:        proc "c" (ctx: ^Context, this_val: Value, val: Value, magic: c.int) -> Value,
    iterator_next:       proc "c" (
        ctx: ^Context,
        this_val: Value,
        argc: c.int,
        argv: [^]Value,
        pdone: ^c.int,
        magic: c.int,
    ) -> Value,
}

// One entry of a static native-module/property table (`JSCFunctionListEntry`).
C_Function_List_Entry :: struct {
    name:       cstring,
    prop_flags: u8,
    def_type:   u8,
    magic:      i16,
    u:          struct #raw_union {
        func:      struct {
            length: u8,
            cproto: u8,
            cfunc:  C_Function_Type,
        },
        getset:    struct {
            get: C_Function_Type,
            set: C_Function_Type,
        },
        alias:     struct {
            name: cstring,
            base: c.int,
        },
        prop_list: struct {
            tab: ^C_Function_List_Entry,
            len: c.int,
        },
        str:       cstring,
        i32:       i32,
        i64:       i64,
        u64:       u64,
        f64:       f64,
    },
}

// `JS_DEF_*` discriminators for `C_Function_List_Entry.def_type`.
Def_CFunc :: u8(0)
Def_CGetSet :: u8(1)
Def_CGetSet_Magic :: u8(2)
Def_Prop_String :: u8(3)
Def_Prop_Int32 :: u8(4)
Def_Prop_Int64 :: u8(5)
Def_Prop_Double :: u8(6)
Def_Prop_Undefined :: u8(7)
Def_Object :: u8(8)
Def_Alias :: u8(9)
Def_Prop_Symbol :: u8(10)
Def_Prop_Bool :: u8(11)

// Enumerated own property (`JSPropertyEnum`).
Property_Enum :: struct {
    is_enumerable: bool,
    atom:          Atom,
}

// A property's attributes and value/accessor pair (`JSPropertyDescriptor`).
Property_Descriptor :: struct {
    flags:  c.int,
    value:  Value,
    getter: Value,
    setter: Value,
}

// Proxy-style trap table for a custom class (`JSClassExoticMethods`).
// Procs return `< 0` on exception.
Class_Exotic_Methods :: struct {
    get_own_property:       proc "c" (ctx: ^Context, desc: ^Property_Descriptor, obj: Value, prop: Atom) -> c.int,
    get_own_property_names: proc "c" (ctx: ^Context, ptab: ^^Property_Enum, plen: ^u32, obj: Value) -> c.int,
    delete_property:        proc "c" (ctx: ^Context, obj: Value, prop: Atom) -> c.int,
    define_own_property:    proc "c" (
        ctx: ^Context,
        this_obj: Value,
        prop: Atom,
        val: Value,
        getter: Value,
        setter: Value,
        flags: c.int,
    ) -> c.int,
    has_property:           proc "c" (ctx: ^Context, obj: Value, atom: Atom) -> c.int,
    get_property:           proc "c" (ctx: ^Context, obj: Value, atom: Atom, receiver: Value) -> Value,
    set_property:           proc "c" (
        ctx: ^Context,
        obj: Value,
        atom: Atom,
        value: Value,
        receiver: Value,
        flags: c.int,
    ) -> c.int,
}

Class_Finalizer :: proc "c" (rt: ^Runtime, val: Value)
Class_GC_Mark :: proc "c" (rt: ^Runtime, val: Value, mark_func: Mark_Func)

// `flags & Call_Flag_Constructor` means `this_val` is `new.target`.
Class_Call :: proc "c" (
    ctx: ^Context,
    func_obj: Value,
    this_val: Value,
    argc: c.int,
    argv: [^]Value,
    flags: c.int,
) -> Value

Call_Flag_Constructor :: c.int(1 << 0)

// `JSClassDef`.
Class_Def :: struct {
    class_name: cstring,
    finalizer:  Class_Finalizer,
    gc_mark:    Class_GC_Mark,
    call:       Class_Call,
    exotic:     ^Class_Exotic_Methods,
}

EVAL_OPTIONS_VERSION :: c.int(1)

// `JSEvalOptions`. `version` must be `EVAL_OPTIONS_VERSION`.
Eval_Options :: struct {
    version:    c.int,
    eval_flags: c.int,
    filename:   cstring,
    line_num:   c.int,
}

#assert(size_of(Eval_Options) == 24)

Free_Array_Buffer_Data_Func :: proc "c" (rt: ^Runtime, opaque: rawptr, ptr: rawptr)

// Typed array element kind (`JSTypedArrayEnum`).
Typed_Array_Kind :: enum c.int {
    Uint8_Clamped = 0,
    Int8,
    Uint8,
    Int16,
    Uint16,
    Int32,
    Uint32,
    Big_Int64,
    Big_Uint64,
    Float16,
    Float32,
    Float64,
}

// SharedArrayBuffer allocator hooks (`JSSharedArrayBufferFunctions`).
Shared_Array_Buffer_Functions :: struct {
    sab_alloc:  proc "c" (opaque: rawptr, size: c.size_t) -> rawptr,
    sab_free:   proc "c" (opaque: rawptr, ptr: rawptr),
    sab_dup:    proc "c" (opaque: rawptr, ptr: rawptr),
    sab_opaque: rawptr,
}

// `JSPromiseStateEnum`.
Promise_State :: enum c.int {
    Not_A_Promise = -1,
    Pending = 0,
    Fulfilled,
    Rejected,
}

// `JSPromiseHookType`.
Promise_Hook_Type :: enum c.int {
    Init,
    Before,
    After,
    Resolve,
}

// `parent_promise` is only meaningful for `.Init`.
Promise_Hook :: proc "c" (
    ctx: ^Context,
    kind: Promise_Hook_Type,
    promise: Value,
    parent_promise: Value,
    opaque: rawptr,
)

// `JSHostPromiseRejectionTracker`. `is_handled` reports whether the rejection
// has a handler attached.
Host_Promise_Rejection_Tracker :: proc "c" (
    ctx: ^Context,
    promise: Value,
    reason: Value,
    is_handled: bool,
    opaque: rawptr,
)

// `JSModuleNormalizeFunc`. Returns an `js_malloc`-allocated specifier, or nil
// on exception.
Module_Normalize_Func :: proc "c" (
    ctx: ^Context,
    module_base_name: cstring,
    module_name: cstring,
    opaque: rawptr,
) -> cstring

// Import-attributes-aware variant of `Module_Normalize_Func`
// (`JSModuleNormalizeFunc2`).
Module_Normalize_Func2 :: proc "c" (
    ctx: ^Context,
    module_base_name: cstring,
    module_name: cstring,
    attributes: Value,
    opaque: rawptr,
) -> cstring

Module_Loader_Func :: proc "c" (ctx: ^Context, module_name: cstring, opaque: rawptr) -> ^Module_Def

// Import-attributes-aware variant of `Module_Loader_Func`
// (`JSModuleLoaderFunc2`).
Module_Loader_Func2 :: proc "c" (ctx: ^Context, module_name: cstring, opaque: rawptr, attributes: Value) -> ^Module_Def

// `JSModuleCheckSupportedImportAttributes`. Returns nonzero if the loader
// should reject `attributes`.
Module_Check_Supported_Import_Attributes :: proc "c" (ctx: ^Context, opaque: rawptr, attributes: Value) -> c.int

Module_Init_Func :: proc "c" (ctx: ^Context, m: ^Module_Def) -> c.int

// `JSSABTab`.
SAB_Tab :: struct {
    tab: ^^u8,
    len: c.size_t,
}

Job_Func :: proc "c" (ctx: ^Context, argc: c.int, argv: [^]Value) -> Value

// `JS_GetOwnPropertyNames` selection mask (`JS_GPN_*`).
Property_Enum_Flag :: enum c.int {
    String    = 0, // 1<<0
    Symbol    = 1, // 1<<1
    Private   = 2, // 1<<2
    Enum_Only = 4, // 1<<4, gap at bit 3 in the C header
    Set_Enum  = 5, // 1<<5
}

Property_Enum_Flags :: bit_set[Property_Enum_Flag;c.int]

// `JS_DefineProperty` / `JS_SetProperty` / `JS_DeleteProperty` flag bits
// (`JS_PROP_*`). Plain `c.int` constants — `JS_PROP_TMASK` is a two-bit
// sub-field that a single-bit enum cannot represent.
Prop_Configurable :: c.int(1 << 0)
Prop_Writable :: c.int(1 << 1)
Prop_Enumerable :: c.int(1 << 2)
Prop_C_W_E :: Prop_Configurable | Prop_Writable | Prop_Enumerable
Prop_Has_Configurable :: c.int(1 << 8)
Prop_Has_Writable :: c.int(1 << 9)
Prop_Has_Enumerable :: c.int(1 << 10)
Prop_Has_Get :: c.int(1 << 11)
Prop_Has_Set :: c.int(1 << 12)
Prop_Has_Value :: c.int(1 << 13)
Prop_Throw :: c.int(1 << 14)
Prop_Throw_Strict :: c.int(1 << 15)

// `JS_WriteObject` / `JS_ReadObject` flag bits (`JS_WRITE_OBJ_*` /
// `JS_READ_OBJ_*`).
Write_Obj_Bytecode :: c.int(1 << 0)
Write_Obj_SAB :: c.int(1 << 2)
Write_Obj_Reference :: c.int(1 << 3)
Write_Obj_Strip_Source :: c.int(1 << 4)
Write_Obj_Strip_Debug :: c.int(1 << 5)
Read_Obj_Bytecode :: c.int(1 << 0)
Read_Obj_SAB :: c.int(1 << 2)
Read_Obj_Reference :: c.int(1 << 3)

// `JS_SetDumpFlags` bit positions (`JS_DUMP_*`).
Dump_Flag :: enum u64 {
    Bytecode_Final   = 0, // 0x01
    Bytecode_Pass2   = 1, // 0x02
    Bytecode_Pass1   = 2, // 0x04
    Bytecode_Hex     = 4, // 0x10
    Bytecode_Pc2line = 5, // 0x20
    Bytecode_Stack   = 6, // 0x40
    Bytecode_Step    = 7, // 0x80
    Read_Object      = 8,
    Free             = 9,
    Gc               = 10,
    Gc_Free          = 11,
    Module_Resolve   = 12,
    Promise          = 13,
    Leaks            = 14,
    Atom_Leaks       = 15,
    Mem              = 16,
    Objects          = 17,
    Atoms            = 18,
    Shapes           = 19,
}

Dump_Flags :: bit_set[Dump_Flag;u64]

// quickjs.h ORs in an otherwise-unnamed bit alongside Leaks|Atom_Leaks, so
// this is not representable as a `Dump_Flags` literal.
ABORT_ON_LEAKS :: u64(0x10C000)

when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
    foreign import lib "bin/windows_amd64/quickjs.lib"
} else when ODIN_OS == .Linux && ODIN_ARCH == .amd64 {
    foreign import lib "bin/linux_amd64/quickjs.a"
} else when ODIN_OS == .Linux && ODIN_ARCH == .arm64 {
    foreign import lib "bin/linux_arm64/quickjs.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
    foreign import lib "bin/darwin_arm64/quickjs.a"
} else when ODIN_OS == .Darwin && ODIN_ARCH == .amd64 {
    foreign import lib "bin/darwin_amd64/quickjs.a"
} else {
    #panic("libs:bindings/quickjs has no archive for this target; see libs/bindings/quickjs/amalgamation/README.md")
}

// Not bound: `js_std_cmd` and `js_string_codePointRange`. The first is the
// private pairing point between the amalgamated core and quickjs-libc.c; the
// second is test scaffolding gated behind a build flag upstream.
@(private, default_calling_convention = "c")
foreign lib {
    @(link_name = "JS_NewRuntime")
    c_new_runtime :: proc() -> ^Runtime ---
    @(link_name = "JS_SetRuntimeInfo")
    c_set_runtime_info :: proc(rt: ^Runtime, info: cstring) ---
    @(link_name = "JS_SetDumpFlags")
    c_set_dump_flags :: proc(rt: ^Runtime, flags: u64) ---
    @(link_name = "JS_GetDumpFlags")
    c_get_dump_flags :: proc(rt: ^Runtime) -> u64 ---
    @(link_name = "JS_GetGCThreshold")
    c_get_gc_threshold :: proc(rt: ^Runtime) -> c.size_t ---
    @(link_name = "JS_UpdateStackTop")
    c_update_stack_top :: proc(rt: ^Runtime) ---
    @(link_name = "JS_NewRuntime2")
    c_new_runtime2 :: proc(mf: ^Alloc_Functions, user: rawptr) -> ^Runtime ---
    @(link_name = "JS_FreeRuntime")
    c_free_runtime :: proc(rt: ^Runtime) ---
    @(link_name = "JS_GetRuntimeOpaque")
    c_get_runtime_opaque :: proc(rt: ^Runtime) -> rawptr ---
    @(link_name = "JS_SetRuntimeOpaque")
    c_set_runtime_opaque :: proc(rt: ^Runtime, user: rawptr) ---
    @(link_name = "JS_AddRuntimeFinalizer")
    c_add_runtime_finalizer :: proc(rt: ^Runtime, finalizer: Runtime_Finalizer, arg: rawptr) -> c.int ---
    @(link_name = "JS_MarkValue")
    c_mark_value :: proc(rt: ^Runtime, val: Value, mark_func: Mark_Func) ---
    @(link_name = "JS_RunGC")
    c_run_gc :: proc(rt: ^Runtime) ---
    @(link_name = "JS_IsLiveObject")
    c_is_live_object :: proc(rt: ^Runtime, obj: Value) -> bool ---

    @(link_name = "JS_NewContext")
    c_new_context :: proc(rt: ^Runtime) -> ^Context ---
    @(link_name = "JS_FreeContext")
    c_free_context :: proc(ctx: ^Context) ---
    @(link_name = "JS_DupContext")
    c_dup_context :: proc(ctx: ^Context) -> ^Context ---
    @(link_name = "JS_GetContextOpaque")
    c_get_context_opaque :: proc(ctx: ^Context) -> rawptr ---
    @(link_name = "JS_SetContextOpaque")
    c_set_context_opaque :: proc(ctx: ^Context, user: rawptr) ---
    @(link_name = "JS_GetRuntime")
    c_get_runtime :: proc(ctx: ^Context) -> ^Runtime ---
    @(link_name = "JS_SetClassProto")
    c_set_class_proto :: proc(ctx: ^Context, class_id: Class_ID, obj: Value) ---
    @(link_name = "JS_GetClassProto")
    c_get_class_proto :: proc(ctx: ^Context, class_id: Class_ID) -> Value ---
    @(link_name = "JS_GetFunctionProto")
    c_get_function_proto :: proc(ctx: ^Context) -> Value ---

    @(link_name = "JS_NewContextRaw")
    c_new_context_raw :: proc(rt: ^Runtime) -> ^Context ---
    @(link_name = "JS_AddIntrinsicBaseObjects")
    c_add_intrinsic_base_objects :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicDate")
    c_add_intrinsic_date :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicEval")
    c_add_intrinsic_eval :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicRegExpCompiler")
    c_add_intrinsic_regexp_compiler :: proc(ctx: ^Context) ---
    @(link_name = "JS_AddIntrinsicRegExp")
    c_add_intrinsic_regexp :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicJSON")
    c_add_intrinsic_json :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicProxy")
    c_add_intrinsic_proxy :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicMapSet")
    c_add_intrinsic_map_set :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicTypedArrays")
    c_add_intrinsic_typed_arrays :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicPromise")
    c_add_intrinsic_promise :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicBigInt")
    c_add_intrinsic_bigint :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicWeakRef")
    c_add_intrinsic_weakref :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddPerformance")
    c_add_performance :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicDOMException")
    c_add_intrinsic_dom_exception :: proc(ctx: ^Context) -> c.int ---
    @(link_name = "JS_AddIntrinsicAToB")
    c_add_intrinsic_atob :: proc(ctx: ^Context) -> c.int ---

    @(link_name = "JS_IsEqual")
    c_is_equal :: proc(ctx: ^Context, op1, op2: Value) -> c.int ---
    @(link_name = "JS_IsStrictEqual")
    c_is_strict_equal :: proc(ctx: ^Context, op1, op2: Value) -> bool ---
    @(link_name = "JS_IsSameValue")
    c_is_same_value :: proc(ctx: ^Context, op1, op2: Value) -> bool ---
    @(link_name = "JS_IsSameValueZero")
    c_is_same_value_zero :: proc(ctx: ^Context, op1, op2: Value) -> bool ---

    @(link_name = "js_calloc_rt")
    c_calloc_rt :: proc(rt: ^Runtime, count, size: c.size_t) -> rawptr ---
    @(link_name = "js_malloc_rt")
    c_malloc_rt :: proc(rt: ^Runtime, size: c.size_t) -> rawptr ---
    @(link_name = "js_free_rt")
    c_free_rt :: proc(rt: ^Runtime, ptr: rawptr) ---
    @(link_name = "js_realloc_rt")
    c_realloc_rt :: proc(rt: ^Runtime, ptr: rawptr, size: c.size_t) -> rawptr ---
    @(link_name = "js_malloc_usable_size_rt")
    c_malloc_usable_size_rt :: proc(rt: ^Runtime, ptr: rawptr) -> c.size_t ---
    @(link_name = "js_mallocz_rt")
    c_mallocz_rt :: proc(rt: ^Runtime, size: c.size_t) -> rawptr ---
    @(link_name = "js_calloc")
    c_calloc :: proc(ctx: ^Context, count, size: c.size_t) -> rawptr ---
    @(link_name = "js_malloc")
    c_malloc :: proc(ctx: ^Context, size: c.size_t) -> rawptr ---
    @(link_name = "js_free")
    c_free :: proc(ctx: ^Context, ptr: rawptr) ---
    @(link_name = "js_realloc")
    c_realloc :: proc(ctx: ^Context, ptr: rawptr, size: c.size_t) -> rawptr ---
    @(link_name = "js_malloc_usable_size")
    c_malloc_usable_size :: proc(ctx: ^Context, ptr: rawptr) -> c.size_t ---
    @(link_name = "js_realloc2")
    c_realloc2 :: proc(ctx: ^Context, ptr: rawptr, size: c.size_t, pslack: ^c.size_t) -> rawptr ---
    @(link_name = "js_mallocz")
    c_mallocz :: proc(ctx: ^Context, size: c.size_t) -> rawptr ---
    @(link_name = "js_strdup")
    c_strdup :: proc(ctx: ^Context, str: cstring) -> cstring ---
    @(link_name = "js_strndup")
    c_strndup :: proc(ctx: ^Context, s: cstring, n: c.size_t) -> cstring ---

    @(link_name = "JS_SetMemoryLimit")
    c_set_memory_limit :: proc(rt: ^Runtime, limit: c.size_t) ---
    @(link_name = "JS_SetGCThreshold")
    c_set_gc_threshold :: proc(rt: ^Runtime, threshold: c.size_t) ---
    @(link_name = "JS_SetMaxStackSize")
    c_set_max_stack_size :: proc(rt: ^Runtime, size: c.size_t) ---
    @(link_name = "JS_ComputeMemoryUsage")
    c_compute_memory_usage :: proc(rt: ^Runtime, out: ^Memory_Usage) ---
    @(link_name = "JS_DumpMemoryUsage")
    c_dump_memory_usage :: proc(fp: rawptr, s: ^Memory_Usage, rt: ^Runtime) ---

    @(link_name = "JS_NewAtomLen")
    c_new_atom_len :: proc(ctx: ^Context, str: cstring, len: c.size_t) -> Atom ---
    @(link_name = "JS_NewAtom")
    c_new_atom :: proc(ctx: ^Context, str: cstring) -> Atom ---
    @(link_name = "JS_NewAtomUInt32")
    c_new_atom_u32 :: proc(ctx: ^Context, n: u32) -> Atom ---
    @(link_name = "JS_DupAtom")
    c_dup_atom :: proc(ctx: ^Context, v: Atom) -> Atom ---
    @(link_name = "JS_DupAtomRT")
    c_dup_atom_rt :: proc(rt: ^Runtime, v: Atom) -> Atom ---
    @(link_name = "JS_FreeAtom")
    c_free_atom :: proc(ctx: ^Context, v: Atom) ---
    @(link_name = "JS_FreeAtomRT")
    c_free_atom_rt :: proc(rt: ^Runtime, v: Atom) ---
    @(link_name = "JS_AtomToValue")
    c_atom_to_value :: proc(ctx: ^Context, atom: Atom) -> Value ---
    @(link_name = "JS_AtomToString")
    c_atom_to_string :: proc(ctx: ^Context, atom: Atom) -> Value ---
    @(link_name = "JS_AtomToCStringLen")
    c_atom_to_cstring_len :: proc(ctx: ^Context, plen: ^c.size_t, atom: Atom) -> cstring ---
    @(link_name = "JS_ValueToAtom")
    c_value_to_atom :: proc(ctx: ^Context, val: Value) -> Atom ---

    @(link_name = "JS_NewClassID")
    c_new_class_id :: proc(rt: ^Runtime, pclass_id: ^Class_ID) -> Class_ID ---
    @(link_name = "JS_GetClassID")
    c_get_class_id :: proc(v: Value) -> Class_ID ---
    @(link_name = "JS_NewClass")
    c_new_class :: proc(rt: ^Runtime, class_id: Class_ID, class_def: ^Class_Def) -> c.int ---
    @(link_name = "JS_IsRegisteredClass")
    c_is_registered_class :: proc(rt: ^Runtime, class_id: Class_ID) -> bool ---
    @(link_name = "JS_GetClassName")
    c_get_class_name :: proc(rt: ^Runtime, class_id: Class_ID) -> Atom ---

    @(link_name = "JS_NewNumber")
    c_new_number :: proc(ctx: ^Context, d: f64) -> Value ---
    @(link_name = "JS_NewBigInt64")
    c_new_bigint64 :: proc(ctx: ^Context, v: i64) -> Value ---
    @(link_name = "JS_NewBigUint64")
    c_new_biguint64 :: proc(ctx: ^Context, v: u64) -> Value ---

    @(link_name = "JS_Throw")
    c_throw :: proc(ctx: ^Context, obj: Value) -> Value ---
    @(link_name = "JS_GetException")
    c_get_exception :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_HasException")
    c_has_exception :: proc(ctx: ^Context) -> bool ---
    @(link_name = "JS_IsError")
    c_is_error :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsUncatchableError")
    c_is_uncatchable_error :: proc(val: Value) -> bool ---
    @(link_name = "JS_SetUncatchableError")
    c_set_uncatchable_error :: proc(ctx: ^Context, val: Value) ---
    @(link_name = "JS_ClearUncatchableError")
    c_clear_uncatchable_error :: proc(ctx: ^Context, val: Value) ---
    @(link_name = "JS_ResetUncatchableError")
    c_reset_uncatchable_error :: proc(ctx: ^Context) ---
    @(link_name = "JS_NewError")
    c_new_error :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_NewInternalError")
    c_new_internal_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_NewPlainError")
    c_new_plain_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_NewRangeError")
    c_new_range_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_NewReferenceError")
    c_new_reference_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_NewSyntaxError")
    c_new_syntax_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_NewTypeError")
    c_new_type_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowInternalError")
    c_throw_internal_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowPlainError")
    c_throw_plain_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowRangeError")
    c_throw_range_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowReferenceError")
    c_throw_reference_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowSyntaxError")
    c_throw_syntax_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowTypeError")
    c_throw_type_error :: proc(ctx: ^Context, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowDOMException")
    c_throw_dom_exception :: proc(ctx: ^Context, name: cstring, fmt: cstring, #c_vararg args: ..any) -> Value ---
    @(link_name = "JS_ThrowOutOfMemory")
    c_throw_out_of_memory :: proc(ctx: ^Context) -> Value ---

    @(link_name = "JS_FreeValue")
    c_free_value :: proc(ctx: ^Context, v: Value) ---
    @(link_name = "JS_FreeValueRT")
    c_free_value_rt :: proc(rt: ^Runtime, v: Value) ---
    @(link_name = "JS_DupValue")
    c_dup_value :: proc(ctx: ^Context, v: Value) -> Value ---
    @(link_name = "JS_DupValueRT")
    c_dup_value_rt :: proc(rt: ^Runtime, v: Value) -> Value ---
    @(link_name = "JS_ToBool")
    c_to_bool :: proc(ctx: ^Context, val: Value) -> c.int ---
    @(link_name = "JS_ToNumber")
    c_to_number :: proc(ctx: ^Context, val: Value) -> Value ---
    @(link_name = "JS_ToInt32")
    c_to_i32 :: proc(ctx: ^Context, out: ^i32, val: Value) -> c.int ---
    @(link_name = "JS_ToInt64")
    c_to_i64 :: proc(ctx: ^Context, out: ^i64, val: Value) -> c.int ---
    @(link_name = "JS_ToIndex")
    c_to_index :: proc(ctx: ^Context, plen: ^u64, val: Value) -> c.int ---
    @(link_name = "JS_ToFloat64")
    c_to_f64 :: proc(ctx: ^Context, out: ^f64, val: Value) -> c.int ---
    @(link_name = "JS_ToBigInt64")
    c_to_bigint64 :: proc(ctx: ^Context, pres: ^i64, val: Value) -> c.int ---
    @(link_name = "JS_ToBigUint64")
    c_to_biguint64 :: proc(ctx: ^Context, pres: ^u64, val: Value) -> c.int ---
    @(link_name = "JS_ToInt64Ext")
    c_to_i64_ext :: proc(ctx: ^Context, pres: ^i64, val: Value) -> c.int ---

    @(link_name = "JS_NewStringLen")
    c_new_string_len :: proc(ctx: ^Context, str: cstring, len: c.size_t) -> Value ---
    @(link_name = "JS_NewStringUTF16")
    c_new_string_utf16 :: proc(ctx: ^Context, buf: [^]u16, len: c.size_t) -> Value ---
    @(link_name = "JS_NewAtomString")
    c_new_atom_string :: proc(ctx: ^Context, str: cstring) -> Value ---
    @(link_name = "JS_ToString")
    c_to_js_string :: proc(ctx: ^Context, val: Value) -> Value ---
    @(link_name = "JS_ToPropertyKey")
    c_to_property_key :: proc(ctx: ^Context, val: Value) -> Value ---
    @(link_name = "JS_ToCStringLen2")
    c_to_cstring_len2 :: proc(ctx: ^Context, plen: ^c.size_t, val: Value, cesu8: bool) -> cstring ---
    @(link_name = "JS_ToCStringLenUTF16")
    c_to_cstring_len_utf16 :: proc(ctx: ^Context, plen: ^c.size_t, val: Value) -> [^]u16 ---
    @(link_name = "JS_FreeCString")
    c_free_cstring :: proc(ctx: ^Context, ptr: cstring) ---
    @(link_name = "JS_FreeCStringRT")
    c_free_cstring_rt :: proc(rt: ^Runtime, ptr: cstring) ---
    @(link_name = "JS_FreeCStringUTF16")
    c_free_cstring_utf16 :: proc(ctx: ^Context, ptr: [^]u16) ---
    @(link_name = "JS_FreeCStringRT_UTF16")
    c_free_cstring_rt_utf16 :: proc(rt: ^Runtime, ptr: [^]u16) ---

    @(link_name = "JS_NewObjectProtoClass")
    c_new_object_proto_class :: proc(ctx: ^Context, proto: Value, class_id: Class_ID) -> Value ---
    @(link_name = "JS_NewObjectClass")
    c_new_object_class :: proc(ctx: ^Context, class_id: Class_ID) -> Value ---
    @(link_name = "JS_NewObjectProto")
    c_new_object_proto :: proc(ctx: ^Context, proto: Value) -> Value ---
    @(link_name = "JS_NewObject")
    c_new_object :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_NewObjectFrom")
    c_new_object_from :: proc(ctx: ^Context, count: c.int, props: [^]Atom, values: [^]Value) -> Value ---
    @(link_name = "JS_NewObjectFromStr")
    c_new_object_from_str :: proc(ctx: ^Context, count: c.int, props: [^]cstring, values: [^]Value) -> Value ---
    @(link_name = "JS_ToObject")
    c_to_object :: proc(ctx: ^Context, val: Value) -> Value ---
    @(link_name = "JS_ToObjectString")
    c_to_object_string :: proc(ctx: ^Context, val: Value) -> Value ---

    @(link_name = "JS_IsFunction")
    c_is_function :: proc(ctx: ^Context, val: Value) -> bool ---
    @(link_name = "JS_IsAsyncFunction")
    c_is_async_function :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsConstructor")
    c_is_constructor :: proc(ctx: ^Context, val: Value) -> bool ---
    @(link_name = "JS_SetConstructorBit")
    c_set_constructor_bit :: proc(ctx: ^Context, func_obj: Value, val: bool) -> bool ---

    @(link_name = "JS_IsRegExp")
    c_is_regexp :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsMap")
    c_is_map :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsSet")
    c_is_set :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsWeakRef")
    c_is_weak_ref :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsWeakSet")
    c_is_weak_set :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsWeakMap")
    c_is_weak_map :: proc(val: Value) -> bool ---
    @(link_name = "JS_IsDataView")
    c_is_data_view :: proc(val: Value) -> bool ---

    @(link_name = "JS_NewArray")
    c_new_array :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_NewArrayFrom")
    c_new_array_from :: proc(ctx: ^Context, count: c.int, values: [^]Value) -> Value ---
    @(link_name = "JS_IsArray")
    c_is_array :: proc(val: Value) -> bool ---

    @(link_name = "JS_IsProxy")
    c_is_proxy :: proc(val: Value) -> bool ---
    @(link_name = "JS_GetProxyTarget")
    c_get_proxy_target :: proc(ctx: ^Context, proxy: Value) -> Value ---
    @(link_name = "JS_GetProxyHandler")
    c_get_proxy_handler :: proc(ctx: ^Context, proxy: Value) -> Value ---
    @(link_name = "JS_NewProxy")
    c_new_proxy :: proc(ctx: ^Context, target: Value, handler: Value) -> Value ---

    @(link_name = "JS_NewDate")
    c_new_date :: proc(ctx: ^Context, epoch_ms: f64) -> Value ---
    @(link_name = "JS_IsDate")
    c_is_date :: proc(v: Value) -> bool ---

    @(link_name = "JS_GetProperty")
    c_get_property :: proc(ctx: ^Context, this_obj: Value, prop: Atom) -> Value ---
    @(link_name = "JS_GetPropertyUint32")
    c_get_property_u32 :: proc(ctx: ^Context, obj: Value, idx: u32) -> Value ---
    @(link_name = "JS_GetPropertyInt64")
    c_get_property_i64 :: proc(ctx: ^Context, this_obj: Value, idx: i64) -> Value ---
    @(link_name = "JS_GetPropertyStr")
    c_get_property_str :: proc(ctx: ^Context, obj: Value, prop: cstring) -> Value ---

    @(link_name = "JS_SetProperty")
    c_set_property :: proc(ctx: ^Context, this_obj: Value, prop: Atom, val: Value) -> c.int ---
    @(link_name = "JS_SetPropertyUint32")
    c_set_property_u32 :: proc(ctx: ^Context, obj: Value, idx: u32, val: Value) -> c.int ---
    @(link_name = "JS_SetPropertyInt64")
    c_set_property_i64 :: proc(ctx: ^Context, this_obj: Value, idx: i64, val: Value) -> c.int ---
    @(link_name = "JS_SetPropertyStr")
    c_set_property_str :: proc(ctx: ^Context, obj: Value, prop: cstring, val: Value) -> c.int ---
    @(link_name = "JS_HasProperty")
    c_has_property :: proc(ctx: ^Context, this_obj: Value, prop: Atom) -> c.int ---
    @(link_name = "JS_IsExtensible")
    c_is_extensible :: proc(ctx: ^Context, obj: Value) -> c.int ---
    @(link_name = "JS_PreventExtensions")
    c_prevent_extensions :: proc(ctx: ^Context, obj: Value) -> c.int ---
    @(link_name = "JS_DeleteProperty")
    c_delete_property :: proc(ctx: ^Context, obj: Value, prop: Atom, flags: c.int) -> c.int ---
    @(link_name = "JS_SetPrototype")
    c_set_prototype :: proc(ctx: ^Context, obj: Value, proto_val: Value) -> c.int ---
    @(link_name = "JS_GetPrototype")
    c_get_prototype :: proc(ctx: ^Context, val: Value) -> Value ---
    @(link_name = "JS_GetLength")
    c_get_length :: proc(ctx: ^Context, obj: Value, pres: ^i64) -> c.int ---
    @(link_name = "JS_SetLength")
    c_set_length :: proc(ctx: ^Context, obj: Value, len: i64) -> c.int ---
    @(link_name = "JS_SealObject")
    c_seal_object :: proc(ctx: ^Context, obj: Value) -> c.int ---
    @(link_name = "JS_FreezeObject")
    c_freeze_object :: proc(ctx: ^Context, obj: Value) -> c.int ---

    @(link_name = "JS_GetOwnPropertyNames")
    c_get_own_property_names :: proc(ctx: ^Context, ptab: ^^Property_Enum, plen: ^u32, obj: Value, flags: c.int) -> c.int ---
    @(link_name = "JS_GetOwnProperty")
    c_get_own_property :: proc(ctx: ^Context, desc: ^Property_Descriptor, obj: Value, prop: Atom) -> c.int ---
    @(link_name = "JS_FreePropertyEnum")
    c_free_property_enum :: proc(ctx: ^Context, tab: [^]Property_Enum, len: u32) ---

    @(link_name = "JS_Call")
    c_call :: proc(ctx: ^Context, func_obj: Value, this_obj: Value, argc: c.int, argv: [^]Value) -> Value ---
    @(link_name = "JS_Invoke")
    c_invoke :: proc(ctx: ^Context, this_val: Value, atom: Atom, argc: c.int, argv: [^]Value) -> Value ---
    @(link_name = "JS_CallConstructor")
    c_call_constructor :: proc(ctx: ^Context, func_obj: Value, argc: c.int, argv: [^]Value) -> Value ---
    @(link_name = "JS_CallConstructor2")
    c_call_constructor2 :: proc(ctx: ^Context, func_obj: Value, new_target: Value, argc: c.int, argv: [^]Value) -> Value ---
    @(link_name = "JS_DetectModule")
    c_detect_module :: proc(input: cstring, input_len: c.size_t) -> bool ---
    @(link_name = "JS_Eval")
    c_eval :: proc(ctx: ^Context, input: cstring, input_len: c.size_t, filename: cstring, flags: c.int) -> Value ---
    @(link_name = "JS_Eval2")
    c_eval2 :: proc(ctx: ^Context, input: cstring, input_len: c.size_t, options: ^Eval_Options) -> Value ---
    @(link_name = "JS_EvalThis")
    c_eval_this :: proc(ctx: ^Context, this_obj: Value, input: cstring, input_len: c.size_t, filename: cstring, eval_flags: c.int) -> Value ---
    @(link_name = "JS_EvalThis2")
    c_eval_this2 :: proc(ctx: ^Context, this_obj: Value, input: cstring, input_len: c.size_t, options: ^Eval_Options) -> Value ---
    @(link_name = "JS_GetGlobalObject")
    c_get_global_object :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_IsInstanceOf")
    c_is_instance_of :: proc(ctx: ^Context, val: Value, obj: Value) -> c.int ---
    @(link_name = "JS_DefineProperty")
    c_define_property :: proc(ctx: ^Context, this_obj: Value, prop: Atom, val: Value, getter: Value, setter: Value, flags: c.int) -> c.int ---
    @(link_name = "JS_DefinePropertyValue")
    c_define_property_value :: proc(ctx: ^Context, this_obj: Value, prop: Atom, val: Value, flags: c.int) -> c.int ---
    @(link_name = "JS_DefinePropertyValueUint32")
    c_define_property_value_u32 :: proc(ctx: ^Context, this_obj: Value, idx: u32, val: Value, flags: c.int) -> c.int ---
    @(link_name = "JS_DefinePropertyValueStr")
    c_define_property_value_str :: proc(ctx: ^Context, this_obj: Value, prop: cstring, val: Value, flags: c.int) -> c.int ---
    @(link_name = "JS_DefinePropertyGetSet")
    c_define_property_getset :: proc(ctx: ^Context, this_obj: Value, prop: Atom, getter: Value, setter: Value, flags: c.int) -> c.int ---
    @(link_name = "JS_SetOpaque")
    c_set_opaque :: proc(obj: Value, opaque: rawptr) -> c.int ---
    @(link_name = "JS_GetOpaque")
    c_get_opaque :: proc(obj: Value, class_id: Class_ID) -> rawptr ---
    @(link_name = "JS_GetOpaque2")
    c_get_opaque2 :: proc(ctx: ^Context, obj: Value, class_id: Class_ID) -> rawptr ---
    @(link_name = "JS_GetAnyOpaque")
    c_get_any_opaque :: proc(obj: Value, class_id: ^Class_ID) -> rawptr ---

    @(link_name = "JS_ParseJSON")
    c_parse_json :: proc(ctx: ^Context, buf: cstring, buf_len: c.size_t, filename: cstring) -> Value ---
    @(link_name = "JS_JSONStringify")
    c_json_stringify :: proc(ctx: ^Context, obj: Value, replacer: Value, space0: Value) -> Value ---

    @(link_name = "JS_NewArrayBuffer")
    c_new_array_buffer :: proc(ctx: ^Context, buf: [^]u8, len: c.size_t, free_func: Free_Array_Buffer_Data_Func, opaque: rawptr, is_shared: bool) -> Value ---
    @(link_name = "JS_NewArrayBufferCopy")
    c_new_array_buffer_copy :: proc(ctx: ^Context, buf: [^]u8, len: c.size_t) -> Value ---
    @(link_name = "JS_DetachArrayBuffer")
    c_detach_array_buffer :: proc(ctx: ^Context, obj: Value) ---
    @(link_name = "JS_GetArrayBuffer")
    c_get_array_buffer :: proc(ctx: ^Context, psize: ^c.size_t, obj: Value) -> [^]u8 ---
    @(link_name = "JS_IsArrayBuffer")
    c_is_array_buffer :: proc(obj: Value) -> bool ---
    @(link_name = "JS_IsImmutableArrayBuffer")
    c_is_immutable_array_buffer :: proc(obj: Value) -> c.int ---
    @(link_name = "JS_SetImmutableArrayBuffer")
    c_set_immutable_array_buffer :: proc(obj: Value, immutable: bool) -> c.int ---
    @(link_name = "JS_GetUint8Array")
    c_get_uint8_array :: proc(ctx: ^Context, psize: ^c.size_t, obj: Value) -> [^]u8 ---

    @(link_name = "JS_NewTypedArray")
    c_new_typed_array :: proc(ctx: ^Context, argc: c.int, argv: [^]Value, array_type: Typed_Array_Kind) -> Value ---
    @(link_name = "JS_GetTypedArrayBuffer")
    c_get_typed_array_buffer :: proc(ctx: ^Context, obj: Value, pbyte_offset: ^c.size_t, pbyte_length: ^c.size_t, pbytes_per_element: ^c.size_t) -> Value ---
    @(link_name = "JS_NewUint8Array")
    c_new_uint8_array :: proc(ctx: ^Context, buf: [^]u8, len: c.size_t, free_func: Free_Array_Buffer_Data_Func, opaque: rawptr, is_shared: bool) -> Value ---
    @(link_name = "JS_GetTypedArrayType")
    c_get_typed_array_type :: proc(obj: Value) -> c.int ---
    @(link_name = "JS_NewUint8ArrayCopy")
    c_new_uint8_array_copy :: proc(ctx: ^Context, buf: [^]u8, len: c.size_t) -> Value ---
    @(link_name = "JS_SetSharedArrayBufferFunctions")
    c_set_shared_array_buffer_functions :: proc(rt: ^Runtime, sf: ^Shared_Array_Buffer_Functions) ---

    @(link_name = "JS_NewPromiseCapability")
    c_new_promise_capability :: proc(ctx: ^Context, resolving_funcs: [^]Value) -> Value ---
    @(link_name = "JS_PromiseState")
    c_promise_state :: proc(ctx: ^Context, promise: Value) -> Promise_State ---
    @(link_name = "JS_PromiseResult")
    c_promise_result :: proc(ctx: ^Context, promise: Value) -> Value ---
    @(link_name = "JS_IsPromise")
    c_is_promise :: proc(val: Value) -> bool ---
    @(link_name = "JS_NewSettledPromise")
    c_new_settled_promise :: proc(ctx: ^Context, is_reject: bool, value: Value) -> Value ---

    @(link_name = "JS_NewSymbol")
    c_new_symbol :: proc(ctx: ^Context, description: cstring, is_global: bool) -> Value ---

    @(link_name = "JS_SetPromiseHook")
    c_set_promise_hook :: proc(rt: ^Runtime, promise_hook: Promise_Hook, opaque: rawptr) ---
    @(link_name = "JS_SetHostPromiseRejectionTracker")
    c_set_host_promise_rejection_tracker :: proc(rt: ^Runtime, cb: Host_Promise_Rejection_Tracker, opaque: rawptr) ---
    @(link_name = "JS_SetInterruptHandler")
    c_set_interrupt_handler :: proc(rt: ^Runtime, cb: Interrupt_Handler, user: rawptr) ---
    @(link_name = "JS_SetCanBlock")
    c_set_can_block :: proc(rt: ^Runtime, can_block: bool) ---
    @(link_name = "JS_SetIsHTMLDDA")
    c_set_is_html_dda :: proc(ctx: ^Context, obj: Value) ---

    @(link_name = "JS_SetModuleLoaderFunc")
    c_set_module_loader_func :: proc(rt: ^Runtime, module_normalize: Module_Normalize_Func, module_loader: Module_Loader_Func, opaque: rawptr) ---
    @(link_name = "JS_SetModuleLoaderFunc2")
    c_set_module_loader_func2 :: proc(rt: ^Runtime, module_normalize: Module_Normalize_Func, module_loader: Module_Loader_Func2, module_check_attrs: Module_Check_Supported_Import_Attributes, opaque: rawptr) ---
    @(link_name = "JS_SetModuleNormalizeFunc2")
    c_set_module_normalize_func2 :: proc(rt: ^Runtime, module_normalize: Module_Normalize_Func2) ---
    @(link_name = "JS_GetImportMeta")
    c_get_import_meta :: proc(ctx: ^Context, m: ^Module_Def) -> Value ---
    @(link_name = "JS_GetModuleName")
    c_get_module_name :: proc(ctx: ^Context, m: ^Module_Def) -> Atom ---
    @(link_name = "JS_GetModuleNamespace")
    c_get_module_namespace :: proc(ctx: ^Context, m: ^Module_Def) -> Value ---
    @(link_name = "JS_SetModulePrivateValue")
    c_set_module_private_value :: proc(ctx: ^Context, m: ^Module_Def, val: Value) -> c.int ---
    @(link_name = "JS_GetModulePrivateValue")
    c_get_module_private_value :: proc(ctx: ^Context, m: ^Module_Def) -> Value ---

    @(link_name = "JS_EnqueueJob")
    c_enqueue_job :: proc(ctx: ^Context, job_func: Job_Func, argc: c.int, argv: [^]Value) -> c.int ---
    @(link_name = "JS_IsJobPending")
    c_is_job_pending :: proc(rt: ^Runtime) -> bool ---
    @(link_name = "JS_GetPendingJobContext")
    c_get_pending_job_context :: proc(rt: ^Runtime) -> ^Context ---
    @(link_name = "JS_ExecutePendingJob")
    c_execute_pending_job :: proc(rt: ^Runtime, pctx: ^^Context) -> c.int ---

    @(link_name = "JS_WriteObject")
    c_write_object :: proc(ctx: ^Context, psize: ^c.size_t, obj: Value, flags: c.int) -> [^]u8 ---
    @(link_name = "JS_WriteObject2")
    c_write_object2 :: proc(ctx: ^Context, psize: ^c.size_t, obj: Value, flags: c.int, psab_tab: ^SAB_Tab) -> [^]u8 ---
    @(link_name = "JS_ReadObject")
    c_read_object :: proc(ctx: ^Context, buf: [^]u8, buf_len: c.size_t, flags: c.int) -> Value ---
    @(link_name = "JS_ReadObject2")
    c_read_object2 :: proc(ctx: ^Context, buf: [^]u8, buf_len: c.size_t, flags: c.int, psab_tab: ^SAB_Tab) -> Value ---
    @(link_name = "JS_EvalFunction")
    c_eval_function :: proc(ctx: ^Context, fun_obj: Value) -> Value ---
    @(link_name = "JS_ResolveModule")
    c_resolve_module :: proc(ctx: ^Context, obj: Value) -> c.int ---

    @(link_name = "JS_GetScriptOrModuleName")
    c_get_script_or_module_name :: proc(ctx: ^Context, n_stack_levels: c.int) -> Atom ---
    @(link_name = "JS_LoadModule")
    c_load_module :: proc(ctx: ^Context, basename: cstring, filename: cstring) -> Value ---

    @(link_name = "JS_NewCFunction2")
    c_new_cfunction2 :: proc(ctx: ^Context, fn: C_Function, name: cstring, length: c.int, kind: C_Function_Kind, magic: c.int) -> Value ---
    @(link_name = "JS_NewCFunction3")
    c_new_cfunction3 :: proc(ctx: ^Context, fn: C_Function, name: cstring, length: c.int, kind: C_Function_Kind, magic: c.int, proto_val: Value, n_fields: c.int) -> Value ---
    @(link_name = "JS_NewCFunctionData")
    c_new_cfunction_data :: proc(ctx: ^Context, fn: C_Function_Data, length: c.int, magic: c.int, data_len: c.int, data: [^]Value) -> Value ---
    @(link_name = "JS_NewCFunctionData2")
    c_new_cfunction_data2 :: proc(ctx: ^Context, fn: C_Function_Data, name: cstring, length: c.int, magic: c.int, data_len: c.int, data: [^]Value) -> Value ---
    @(link_name = "JS_NewCClosure")
    c_new_cclosure :: proc(ctx: ^Context, fn: C_Closure, name: cstring, opaque_finalize: C_Closure_Finalizer_Func, length: c.int, magic: c.int, opaque: rawptr) -> Value ---
    @(link_name = "JS_SetConstructor")
    c_set_constructor :: proc(ctx: ^Context, func_obj: Value, proto: Value) -> c.int ---

    @(link_name = "JS_SetPropertyFunctionList")
    c_set_property_function_list :: proc(ctx: ^Context, obj: Value, tab: [^]C_Function_List_Entry, len: c.int) -> c.int ---

    @(link_name = "JS_NewCModule")
    c_new_cmodule :: proc(ctx: ^Context, name_str: cstring, func: Module_Init_Func) -> ^Module_Def ---
    @(link_name = "JS_AddModuleExport")
    c_add_module_export :: proc(ctx: ^Context, m: ^Module_Def, name_str: cstring) -> c.int ---
    @(link_name = "JS_AddModuleExportList")
    c_add_module_export_list :: proc(ctx: ^Context, m: ^Module_Def, tab: [^]C_Function_List_Entry, len: c.int) -> c.int ---
    @(link_name = "JS_SetModuleExport")
    c_set_module_export :: proc(ctx: ^Context, m: ^Module_Def, export_name: cstring, val: Value) -> c.int ---
    @(link_name = "JS_SetModuleExportList")
    c_set_module_export_list :: proc(ctx: ^Context, m: ^Module_Def, tab: [^]C_Function_List_Entry, len: c.int) -> c.int ---

    @(link_name = "JS_GetVersion")
    c_get_version :: proc() -> cstring ---
}
