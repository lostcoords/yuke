package testsupport

import "core:mem"
import "core:testing"

@(test)
test_failing_allocator_injection :: proc(t: ^testing.T) {
    src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&src)

    arena_alloc := mem.dynamic_arena_allocator(&src)
    fa := Failing_Allocator{}
    failing_allocator_init(&fa, arena_alloc, 1)
    alloc := failing_allocator(&fa)

    // First allocation should succeed (count 0 < fail_at 1).
    data1, err1 := make([]u8, 32, alloc)
    testing.expect(t, err1 == nil, "first allocation should succeed")
    testing.expect(t, len(data1) == 32, "first allocation size should match")

    // Second allocation should fail (count 1 >= fail_at 1).
    data2, err2 := make([]u8, 32, alloc)
    testing.expect(t, err2 == .Out_Of_Memory, "second allocation should fail with Out_Of_Memory")
    testing.expect(t, len(data2) == 0, "second allocation should be empty")

    // Every allocation past the fail point stays failed ("once OOM, stay OOM").
    data3, err3 := make([]u8, 32, alloc)
    testing.expect(t, err3 == .Out_Of_Memory, "third allocation should also fail")
    testing.expect(t, len(data3) == 0, "third allocation should be empty")
}

@(test)
test_failing_allocator_respects_fail_point :: proc(t: ^testing.T) {
    src: mem.Dynamic_Arena
    mem.dynamic_arena_init(&src, context.allocator, context.allocator)
    defer mem.dynamic_arena_destroy(&src)

    arena_alloc := mem.dynamic_arena_allocator(&src)

    // Set fail_at = 0 to fail from the first allocation onward.
    fa := Failing_Allocator{}
    failing_allocator_init(&fa, arena_alloc, 0)
    alloc := failing_allocator(&fa)

    // First allocation should immediately fail.
    _, err := make([]u8, 16, alloc)
    testing.expect(t, err == .Out_Of_Memory, "first allocation should fail")

    // Subsequent allocation should also fail — the failure is sticky, not transient.
    _, err2 := make([]u8, 16, alloc)
    testing.expect(t, err2 == .Out_Of_Memory, "second allocation should also fail")
}

@(test)
test_failing_allocator_skips_arena_internal_allocations :: proc(t: ^testing.T) {
    // A Dynamic_Arena backed by the failing allocator: the arena's own block and bookkeeping
    // allocations report `allocators.odin` and must pass through even at fail_at 0, or the
    // failure-unsafe arena would be corrupted. Direct allocations still fail.
    fa := Failing_Allocator{}
    failing_allocator_init(&fa, context.allocator, 0)
    alloc := failing_allocator(&fa)

    arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&arena, alloc, alloc)
    defer mem.dynamic_arena_destroy(&arena)

    arena_alloc := mem.dynamic_arena_allocator(&arena)

    // Allocating through the arena drives arena-internal block allocation, which the guard
    // exempts from the injected failure.
    data, err := make([]u8, 64, arena_alloc)
    testing.expect(t, err == nil, "arena-internal allocation must bypass injected failure")
    testing.expect(t, len(data) == 64, "arena allocation size should match")

    // A direct allocation (caller is this test file) still fails.
    _, derr := make([]u8, 16, alloc)
    testing.expect(t, derr == .Out_Of_Memory, "direct allocation must fail at fail_at 0")
}
