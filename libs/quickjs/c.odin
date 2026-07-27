package quickjs

import "core:c"

// Opaque engine instance (`JSRuntime *`). Owns the heap, the GC, and the job
// queue; one per session so eviction is a single `runtime_free`.
Runtime :: struct {}

// Opaque execution environment (`JSContext *`). Holds the global object and
// intrinsics; several may share one Runtime and its GC.
Context :: struct {}

// Interned property name (`JSAtom`).
Atom :: distinct u32

// Tag discriminating the payload in `Value.u`. Negative tags are reference
// counted. Layout assumes NaN boxing is off, which the build scripts enforce
// by compiling 64-bit only; see `amalgamation/README.md`.
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

// The engine's own ABI. A mismatch here means the archive was built with
// different flags than this binding assumes (NaN boxing, 32-bit) and every
// call would silently corrupt memory.
#assert(size_of(Value) == 16)
#assert(offset_of(Value, tag) == 8)

// Per-runtime allocator hooks (`JSMallocFunctions`). Supplying these is how a
// session VM is bound to its own arena, so eviction reclaims in one shot.
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

// Called periodically while JS runs; return non-zero to abort the script.
// This is the only way to reclaim the thread from a runaway turn.
Interrupt_Handler :: proc "c" (rt: ^Runtime, user: rawptr) -> c.int

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

// foreign import itself cannot be @(private); the c_* decls below are.
// Archives are produced per target by `make quickjs-static`; see
// `amalgamation/README.md`.
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
    #panic("libs:quickjs has no archive for this target; see libs/quickjs/amalgamation/README.md")
}

@(private, default_calling_convention = "c")
foreign lib {
    @(link_name = "JS_NewRuntime")
    c_new_runtime :: proc() -> ^Runtime ---
    @(link_name = "JS_NewRuntime2")
    c_new_runtime2 :: proc(mf: ^Alloc_Functions, user: rawptr) -> ^Runtime ---
    @(link_name = "JS_FreeRuntime")
    c_free_runtime :: proc(rt: ^Runtime) ---
    @(link_name = "JS_SetRuntimeOpaque")
    c_set_runtime_opaque :: proc(rt: ^Runtime, user: rawptr) ---
    @(link_name = "JS_GetRuntimeOpaque")
    c_get_runtime_opaque :: proc(rt: ^Runtime) -> rawptr ---

    @(link_name = "JS_SetMemoryLimit")
    c_set_memory_limit :: proc(rt: ^Runtime, limit: c.size_t) ---
    @(link_name = "JS_SetGCThreshold")
    c_set_gc_threshold :: proc(rt: ^Runtime, threshold: c.size_t) ---
    @(link_name = "JS_SetMaxStackSize")
    c_set_max_stack_size :: proc(rt: ^Runtime, size: c.size_t) ---
    @(link_name = "JS_RunGC")
    c_run_gc :: proc(rt: ^Runtime) ---
    @(link_name = "JS_ComputeMemoryUsage")
    c_compute_memory_usage :: proc(rt: ^Runtime, out: ^Memory_Usage) ---

    @(link_name = "JS_SetInterruptHandler")
    c_set_interrupt_handler :: proc(rt: ^Runtime, cb: Interrupt_Handler, user: rawptr) ---
    @(link_name = "JS_IsJobPending")
    c_is_job_pending :: proc(rt: ^Runtime) -> bool ---
    @(link_name = "JS_ExecutePendingJob")
    c_execute_pending_job :: proc(rt: ^Runtime, pctx: ^^Context) -> c.int ---

    @(link_name = "JS_NewContext")
    c_new_context :: proc(rt: ^Runtime) -> ^Context ---
    @(link_name = "JS_FreeContext")
    c_free_context :: proc(ctx: ^Context) ---
    @(link_name = "JS_GetRuntime")
    c_get_runtime :: proc(ctx: ^Context) -> ^Runtime ---
    @(link_name = "JS_SetContextOpaque")
    c_set_context_opaque :: proc(ctx: ^Context, user: rawptr) ---
    @(link_name = "JS_GetContextOpaque")
    c_get_context_opaque :: proc(ctx: ^Context) -> rawptr ---

    @(link_name = "JS_FreeValue")
    c_free_value :: proc(ctx: ^Context, v: Value) ---
    @(link_name = "JS_FreeValueRT")
    c_free_value_rt :: proc(rt: ^Runtime, v: Value) ---
    @(link_name = "JS_DupValue")
    c_dup_value :: proc(ctx: ^Context, v: Value) -> Value ---

    @(link_name = "JS_Eval")
    c_eval :: proc(ctx: ^Context, input: cstring, input_len: c.size_t, filename: cstring, flags: c.int) -> Value ---
    @(link_name = "JS_Call")
    c_call :: proc(ctx: ^Context, func_obj: Value, this_obj: Value, argc: c.int, argv: [^]Value) -> Value ---
    @(link_name = "JS_GetGlobalObject")
    c_get_global_object :: proc(ctx: ^Context) -> Value ---

    @(link_name = "JS_GetException")
    c_get_exception :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_HasException")
    c_has_exception :: proc(ctx: ^Context) -> bool ---
    @(link_name = "JS_Throw")
    c_throw :: proc(ctx: ^Context, obj: Value) -> Value ---

    @(link_name = "JS_NewObject")
    c_new_object :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_NewArray")
    c_new_array :: proc(ctx: ^Context) -> Value ---
    @(link_name = "JS_GetPropertyStr")
    c_get_property_str :: proc(ctx: ^Context, obj: Value, prop: cstring) -> Value ---
    @(link_name = "JS_SetPropertyStr")
    c_set_property_str :: proc(ctx: ^Context, obj: Value, prop: cstring, val: Value) -> c.int ---
    @(link_name = "JS_GetPropertyUint32")
    c_get_property_u32 :: proc(ctx: ^Context, obj: Value, idx: u32) -> Value ---
    @(link_name = "JS_SetPropertyUint32")
    c_set_property_u32 :: proc(ctx: ^Context, obj: Value, idx: u32, val: Value) -> c.int ---

    @(link_name = "JS_NewCFunction2")
    c_new_cfunction2 :: proc(ctx: ^Context, fn: C_Function, name: cstring, length: c.int, kind: C_Function_Kind, magic: c.int) -> Value ---

    @(link_name = "JS_NewStringLen")
    c_new_string_len :: proc(ctx: ^Context, str: cstring, len: c.size_t) -> Value ---
    @(link_name = "JS_ToCStringLen2")
    c_to_cstring_len2 :: proc(ctx: ^Context, plen: ^c.size_t, val: Value, cesu8: bool) -> cstring ---
    @(link_name = "JS_FreeCString")
    c_free_cstring :: proc(ctx: ^Context, ptr: cstring) ---

    @(link_name = "JS_ToBool")
    c_to_bool :: proc(ctx: ^Context, val: Value) -> c.int ---
    @(link_name = "JS_ToInt32")
    c_to_i32 :: proc(ctx: ^Context, out: ^i32, val: Value) -> c.int ---
    @(link_name = "JS_ToInt64")
    c_to_i64 :: proc(ctx: ^Context, out: ^i64, val: Value) -> c.int ---
    @(link_name = "JS_ToFloat64")
    c_to_f64 :: proc(ctx: ^Context, out: ^f64, val: Value) -> c.int ---

    @(link_name = "JS_NewPromiseCapability")
    c_new_promise_capability :: proc(ctx: ^Context, resolving_funcs: [^]Value) -> Value ---
}
