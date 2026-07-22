package testsupport

import "base:runtime"
import "core:mem"
import "core:strings"

// Failing_Allocator wraps a backing allocator and injects `.Out_Of_Memory` at the `fail_at`-th
// counted allocation. Once the fail point is reached every subsequent allocation also fails
// ("once OOM, stay OOM") — the fault model an exhaustive allocation-failure sweep needs, where a
// run either completes or is starved from a fixed point onward, never a single transient blip
// surrounded by success.
//
// Only alloc/resize modes are counted and can fail; free and query modes always delegate to the
// backing allocator untouched, so the wrapper reports the backing's real feature set.
//
// Not thread-safe: `count` is mutated without synchronization. Intended for single-threaded test
// use with one active allocator at a time.
Failing_Allocator :: struct {
    backing: mem.Allocator,
    fail_at: int,
    count:   int,
}

failing_allocator_init :: proc(fa: ^Failing_Allocator, backing: mem.Allocator, fail_at: int) {
    fa.backing = backing
    fa.fail_at = fail_at
    fa.count = 0
}

failing_allocator :: proc(fa: ^Failing_Allocator) -> mem.Allocator {
    return mem.Allocator{data = fa, procedure = _failing_allocator_procedure}
}

// Allocations that originate inside core's `Dynamic_Arena` implementation — both its backing
// blocks and its `[dynamic]rawptr` block-bookkeeping arrays — pass through without being counted
// or failed. `Dynamic_Arena` is NOT failure-safe: a failed block allocation leaves it in a state
// where the next in-arena allocation faults, and a failed bookkeeping allocation orphans a block
// (leak). Injection is therefore scoped to the caller's OWN direct allocations, which report a
// caller in the caller's source; arena-internal ones report `allocators.odin`.
_is_arena_internal :: proc(loc: runtime.Source_Code_Location) -> bool {
    return strings.contains(loc.file_path, "allocators.odin")
}

_failing_allocator_procedure :: proc(
    allocator_data: rawptr,
    mode: mem.Allocator_Mode,
    size, alignment: int,
    old_memory: rawptr,
    old_size: int,
    location := #caller_location,
) -> (
    []byte,
    mem.Allocator_Error,
) {
    fa := cast(^Failing_Allocator)allocator_data

    #partial switch mode {
    case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
        if !_is_arena_internal(location) {
            if fa.count >= fa.fail_at {
                return nil, .Out_Of_Memory
            }

            fa.count += 1
        }
    }

    return fa.backing.procedure(fa.backing.data, mode, size, alignment, old_memory, old_size, location)
}
