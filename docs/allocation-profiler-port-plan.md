# Allocation Profiler Port Plan

Status: proposal.
Source of truth: allocator ownership in `src/` and `lib/`.
Last verified: 2026-08-31.

## Goal

Build a reusable Zig allocation profiler, based primarily on Jai's
`Basic/Memory_Debugger`, and use it to understand allocation behavior in yuke.

The profiler should answer questions such as:

- Which allocation sites retain the most memory?
- How many allocations and requested bytes occur during a run or tool call?
- What is the peak live memory for a labeled operation?
- Which allocations remain live at shutdown?
- How much memory is logically requested from an arena versus allocated from
  the arena's backing allocator?

This is separate from conventional CPU profiling. CPU zones may be added later
using the useful parts of Jai's `Iprof` runtime model.

## Jai References

The main reference implementation is in the adjacent Jai distribution:

- `~/jai/modules/Basic/Memory_Debugger.jai`
  - Tracks allocation, free, and realloc operations.
  - Records allocation and free stack traces.
  - Detects unknown memory, double frees, and allocator mismatches.
  - Groups outstanding memory by allocation site for leak reports.
- `~/jai/modules/Basic/module.jai`
  - Shows how the debugger is inserted into the allocator operations.
- `~/jai/modules/Basic/examples/memory_debugger.jai`
  - Demonstrates leak reporting and stack grouping.
- `~/jai/modules/Iprof/runtime.jai`
  - Useful later for manual CPU zones, inclusive and exclusive time, and call
    counts.
- `~/jai/modules/Iprof/instrument.jai`
  - Not a practical port target. It relies on Jai compiler AST hooks to insert
    zones automatically, for which Zig has no equivalent library mechanism.

`Default_Allocator_with_statistics` is not a good basis for the port. It is
tied to Jai's allocator implementation and is narrower than the memory
debugger.

## Why the Design Fits Yuke

Yuke already passes `std.mem.Allocator` explicitly through most major systems:

- `src/main.zig` receives `std.process.Init.gpa`.
- `src/daemon/app.zig` uses the GPA for the runtime, state, configuration,
  database paths, and transports.
- `src/daemon/State.zig` stores the allocator for daemon-lifetime state.
- `src/daemon/run_task.zig` creates an arena for a complete model turn.
- `lib/domain/draft.zig` combines write-once arena storage with GPA-backed
  streaming buffers.
- `lib/domain/queue.zig` gives each queued item its own arena.

A profiling allocator can therefore be inserted at the top of the allocator
tree without changing the ownership model.

## Two Required Views

### Global backing allocations

Wrap the top-level GPA and record actual heap activity:

- allocation, resize, remap, and free counts;
- total requested bytes;
- current and peak live bytes;
- allocation size and alignment;
- outstanding allocations grouped by call site;
- invalid, duplicate, or mismatched frees where practical.

This view measures real pressure on the backing allocator.

### Logical arena allocations

A wrapper around only the top-level GPA sees an arena's backing chunks, not
each call to `arena.allocator().alloc`. Thousands of small logical allocations
may consequently appear as a few large backing allocations.

Important arenas should also expose a lightweight labeled counting allocator.
For each scope, record:

- logical allocation calls and requested bytes;
- largest request;
- scope lifetime;
- backing bytes consumed;
- a label such as `startup`, `hydrate_session`, `run_turn`, `draft`,
  `queue_item`, or `tool_scratch`.

Logical live-allocation counts are less meaningful for an arena because
individual frees are intentionally ignored. The useful boundary is the arena
reset or deinitialization.

## Proposed Zig API

The initial library can expose an allocator-compatible profiler:

```zig
const AllocationProfiler = struct {
    backing: std.mem.Allocator,
    metadata_allocator: std.mem.Allocator,

    pub fn allocator(self: *AllocationProfiler) std.mem.Allocator;
    pub fn snapshot(self: *AllocationProfiler, label: []const u8) Snapshot;
    pub fn writeReport(
        self: *AllocationProfiler,
        writer: *std.Io.Writer,
    ) !void;
};
```

The allocator vtable intercepts `alloc`, `resize`, `remap`, and `free`.
Zig supplies a `ret_addr` to these operations, so the first implementation can
group allocations by caller address without capturing a full stack on every
operation. Symbolication can happen while producing the report.

Full stack capture should be optional. It provides more context but carries a
substantially higher cost.

The profiler's tables and report metadata must use an unwrapped allocator.
Using the profiled allocator internally would recursively trigger the
profiler. The implementation should also be thread-safe because yuke uses an
asynchronous runtime and may allocate from multiple tasks or threads.

## Snapshots and Output

Named snapshots should report the delta across an operation:

- allocation and free calls;
- requested and freed bytes;
- change in current live bytes;
- peak live bytes within the interval;
- largest allocation sites.

Initial output should be stable text, JSON, or CSV. A GUI or live visualizer is
not part of the first version. Machine-readable output will make it possible to
compare runs and later build a viewer without coupling it to the profiler.

## Recommended Integration Order

1. Add the global allocation wrapper at the daemon entry point and pass its
   allocator everywhere currently using `init.gpa`.
2. Profile the whole-turn arena in `src/daemon/run_task.zig`. It remains alive
   across model rounds, retries, streamed events, and tool calls, so temporary
   data can accumulate until the run finishes.
3. Separate measurements for the Draft arena and its GPA-backed streaming
   buffers in `lib/domain/draft.zig`.
4. Measure per-item queue arenas and session/run-slot retention.
5. Add labels for startup, session hydration, RPC handling, provider attempts,
   and tool-call scratch arenas.
6. Profile TUI and QuickJS activity after the daemon allocation picture is
   understood.

Native libraries are a blind spot if they allocate internally rather than
through the supplied Zig allocator. SQLite and QuickJS allocations should be
checked with macOS Instruments alongside the semantic reports from this
library.

## Existing Zig Debugging Support

In Debug builds, Zig's process GPA already uses `std.heap.DebugAllocator` and
can report leaks at shutdown. This is useful as a correctness baseline, but it
does not provide the operational view needed here: named snapshots, grouped
live bytes during execution, per-turn peaks, or logical arena activity.

The custom profiler should complement rather than replace DebugAllocator.

## Later CPU Profiling

After allocation profiling is useful, port the manual portion of the `Iprof`
model:

- scoped begin/end zones;
- a thread-local parent-zone stack;
- inclusive and exclusive time;
- entry counts;
- stable text, CSV, or trace output.

Good semantic CPU zones in yuke include `runSession`, stream rounds and
attempts, provider parsing, database operations, tool calls, and QuickJS
evaluation/rendering. Automatic source instrumentation is explicitly out of
scope.

## First Milestone

The first milestone is complete when a daemon run can produce a report with:

- total allocation calls and bytes;
- current and peak live bytes;
- outstanding allocations grouped by return address;
- named deltas for at least `run_turn`;
- logical request totals and backing allocation totals for the turn arena;
- negligible profiler recursion risk and correct behavior under concurrent
  allocation.
