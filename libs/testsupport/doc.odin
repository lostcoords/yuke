/*
package testsupport holds test-only utilities shared across the yuke-odin
packages. Nothing here is linked into production builds.

  - `nbio.odin`: bounded event-loop waits for asynchronous tests, with finite
    per-tick timeouts and named failures when the deadline expires before the
    expected condition.

  - `failing_allocator.odin`: a `mem.Allocator` wrapper that injects
    `.Out_Of_Memory` at the `fail_at`-th counted allocation and stays OOM
    afterward — the fault model an exhaustive allocation-failure sweep needs.
    Only alloc/resize modes are counted; free and query always delegate.
    Allocations originating inside `core`'s `Dynamic_Arena` pass through
    uncounted (that arena is not failure-safe), so injection is scoped to the
    caller's own direct allocations.
*/
package testsupport
