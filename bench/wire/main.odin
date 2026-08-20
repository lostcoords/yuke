// Microbenchmark for the tier-1 server-frame header scan, which routes a frame from
// its member keys alone. Measures whether that cost tracks payload size and whether
// any of it allocates, in both member orders.
//
// The reported floor includes the tracker and the per-iteration arena reset, so the
// absolute numbers are an upper bound; the shape across payload sizes is the result.
package bench_wire

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "src:wire"

// The payload-first order is linear in payload size, so a fixed iteration count
// would let the largest case dominate the run. Scale to roughly constant work.
TARGET_WORK_BYTES :: 32 << 20
MIN_ITERATIONS :: 100
MAX_ITERATIONS :: 20_000

Case :: struct {
    name:  string,
    frame: string,
}

// A `result` payload of roughly `size` bytes, shaped like a transcript page rather
// than one long string, so the token walk sees many members.
build_payload :: proc(size: int, allocator := context.allocator) -> string {
    b := strings.builder_make(allocator)
    strings.write_string(&b, `{"items":[`)
    first := true
    for strings.builder_len(b) < size {
        if !first {
            strings.write_byte(&b, ',')
        }

        first = false
        strings.write_string(&b, `{"type":"queued","input_id":8,"text":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`)
    }

    strings.write_string(&b, `]}`)

    return strings.to_string(b)
}

// Normative order: `jsonrpc`, `id`, then the discriminating member.
frame_in_order :: proc(payload: string, allocator := context.allocator) -> string {
    return strings.concatenate({`{"jsonrpc":"2.0","id":42,"result":`, payload, `}`}, allocator)
}

// Worst case: the payload precedes the routing key, so the scan must reach past it.
frame_payload_first :: proc(payload: string, allocator := context.allocator) -> string {
    return strings.concatenate({`{"result":`, payload, `,"id":42,"jsonrpc":"2.0"}`}, allocator)
}

iterations_for :: proc(frame_bytes: int) -> int {
    return clamp(TARGET_WORK_BYTES / max(frame_bytes, 1), MIN_ITERATIONS, MAX_ITERATIONS)
}

Result :: struct {
    ns_per_op:   f64,
    allocs:      i64,
    peak:        i64,
    heap_allocs: i64,
    iters:       int,
}

run_case :: proc(c: Case) -> (res: Result, ok: bool) {
    res.iters = iterations_for(len(c.frame))

    // Two trackers: `heap` counts what the arena's blocks cost the real allocator,
    // `tracker` counts the scan's own allocator calls. The daemon and client reset
    // their per-frame arena with `free_all`, which releases blocks, so the heap
    // number is the one that says whether this is arena-cheap or malloc-cheap.
    heap: mem.Tracking_Allocator
    mem.tracking_allocator_init(&heap, context.allocator, context.allocator)
    defer mem.tracking_allocator_destroy(&heap)

    backing: mem.Dynamic_Arena
    mem.dynamic_arena_init(&backing, mem.tracking_allocator(&heap), context.allocator)
    defer mem.dynamic_arena_destroy(&backing)

    tracker: mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker, mem.dynamic_arena_allocator(&backing), context.allocator)
    defer mem.tracking_allocator_destroy(&tracker)
    tracked := mem.tracking_allocator(&tracker)

    // Warm up, and confirm the scan succeeds before timing it.
    header, err := wire.server_frame_header_stream(c.frame, tracked)
    if err != .None || header.kind != .Response {
        fmt.eprintfln("case %s: scan failed (%v, %v)", c.name, err, header.kind)
        return res, false
    }

    mem.tracking_allocator_clear(&tracker)
    free_all(tracked)
    mem.tracking_allocator_clear(&heap)

    start := time.now()
    for _ in 0 ..< res.iters {
        h, e := wire.server_frame_header_stream(c.frame, tracked)

        // Consume the outputs so the loop cannot be elided.
        if e != .None || len(string(h.id)) == 0 {
            fmt.eprintfln("case %s: scan regressed mid-run", c.name)
            return res, false
        }

        free_all(tracked)
    }

    elapsed := time.since(start)
    res.ns_per_op = f64(time.duration_nanoseconds(elapsed)) / f64(res.iters)
    res.allocs = tracker.total_allocation_count / i64(res.iters)
    res.peak = tracker.peak_memory_allocated
    res.heap_allocs = heap.total_allocation_count

    return res, true
}

main :: proc() {
    sizes := []int{0, 1 << 10, 64 << 10, 1 << 20}
    cases: [dynamic]Case
    defer delete(cases)
    for size in sizes {
        payload := size == 0 ? `{}` : build_payload(size)
        label := size == 0 ? "empty" : fmt.aprintf("%dKiB", size / 1024)
        append(&cases, Case{fmt.aprintf("in-order   %-8s", label), frame_in_order(payload)})
        append(&cases, Case{fmt.aprintf("payload1st %-8s", label), frame_payload_first(payload)})
    }

    fmt.printfln("header scan — iterations scaled to ~%d MiB of work per case", TARGET_WORK_BYTES >> 20)
    fmt.printfln("%-22s %8s %14s %10s %11s %11s", "case", "iters", "ns/op", "allocs/op", "peak bytes", "heap total")
    for c in cases {
        res, ok := run_case(c)
        if !ok {
            os.exit(1)
        }

        fmt.printfln(
            "%-22s %8d %14.1f %10d %11d %11d",
            c.name,
            res.iters,
            res.ns_per_op,
            res.allocs,
            res.peak,
            res.heap_allocs,
        )
    }
}
