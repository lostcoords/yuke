// Microbenchmark for the terminal input decoder. Measures per-event decode cost across
// the sequence classes a real session produces, whether the parser path allocates at all,
// and what the `Reader` costs on top of it once paste assembly and the cross-read tail are
// in play.
//
// The reported floor includes the tracker and the loop itself, so absolute numbers are an
// upper bound; the shape across classes is the result.
package bench_term

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

import "src:term"

// Enough repetitions that timer resolution stops mattering, without letting the longest
// sequence dominate the run.
TARGET_EVENTS :: 2 << 20

Case :: struct {
    name:  string,
    input: string,
}

// One of each class the decoder actually sees, cheapest first.
CASES := []Case {
    {"ascii byte", "a"},
    {"utf8 2-byte", "\xc3\xa9"},
    {"utf8 4-byte", "\xf0\x9f\x98\x80"},
    {"ctrl byte", "\x01"},
    {"legacy arrow", "\x1b[A"},
    {"legacy modified", "\x1b[1;5C"},
    {"legacy tilde", "\x1b[3;5:3~"},
    {"kitty bare", "\x1b[97u"},
    {"kitty mods+event", "\x1b[97;5:3u"},
    {"kitty alternates", "\x1b[97:65:97;2;65u"},
    {"kitty text x4", "\x1b[97;1;97:98:99:100u"},
    {"kitty text max", "\x1b[97;1;97:97:97:97:97:97:97:97:97:97:97:97:97:97u"},
    {"kitty text-only", "\x1b[0;;229u"},
    {"x10 mouse", "\x1b[M\x20\x21\x22"},
    {"in-band resize", "\x1b[48;24;80;600;800t"},
}

main :: proc() {
    tracker: mem.Tracking_Allocator
    mem.tracking_allocator_init(&tracker, context.allocator)
    context.allocator = mem.tracking_allocator(&tracker)

    report_sizes()
    report_parser()
    report_reader()
    report_paste()

    if len(tracker.allocation_map) != 0 {
        fmt.printfln("\nLEAK: %d allocations still live", len(tracker.allocation_map))
        os.exit(1)
    }
}

report_sizes :: proc() {
    fmt.println("=== sizes (bytes) ===")
    row :: proc(name: string, n: int, note := "") {
        fmt.printfln("%-16s %-6s %s", name, fmt.tprintf("%d", n), note)
    }

    row("Key", size_of(term.Key), fmt.tprintf("(%d of it is the text buffer)", term.MAX_KEY_TEXT_BYTES))
    row("Parse_Event", size_of(term.Parse_Event))
    row("Event", size_of(term.Event))
    row("Mouse", size_of(term.Mouse))
    row("Parser", size_of(term.Parser))
    row("Reader", size_of(term.Reader))
    row("Session", size_of(term.Session))
}

// Drive a fresh parser over `input` byte by byte, the way the reader does.
decode_one :: proc(input: string) -> term.Parse_Event {
    p: term.Parser
    for i in 0 ..< len(input) {
        ev := term.parser_step(&p, input[i])
        if ev != nil {
            return ev
        }
    }

    return nil
}

report_parser :: proc() {
    fmt.println("\n=== parser: per-event decode, no allocator involved ===")
    fmt.printfln("%-20s %-6s %-10s %-9s %s", "case", "bytes", "ns/event", "ns/byte", "Mevent/s")

    for c in CASES {
        iterations := TARGET_EVENTS
        sink := 0

        start := time.tick_now()
        for _ in 0 ..< iterations {
            ev := decode_one(c.input)
            // Keep the result live so the decode cannot be optimized away.
            if ev != nil {
                sink += 1
            }
        }

        elapsed := time.tick_since(start)

        if sink != iterations {
            fmt.printfln("%-20s  DID NOT DECODE (%d/%d)", c.name, sink, iterations)
            continue
        }

        ns_total := f64(time.duration_nanoseconds(elapsed))
        ns_event := ns_total / f64(iterations)
        ns_byte := ns_event / f64(len(c.input))
        fmt.printfln(
            "%-20s %-6s %-10s %-9s %s",
            c.name,
            fmt.tprintf("%d", len(c.input)),
            fmt.tprintf("%.1f", ns_event),
            fmt.tprintf("%.2f", ns_byte),
            fmt.tprintf("%.1f", 1000.0 / ns_event),
        )
    }
}

report_reader :: proc() {
    fmt.println("\n=== reader: push + drain, steady state ===")
    fmt.printfln("%-20s %-10s %-10s %s", "case", "ns/event", "Mevent/s", "allocs")

    for c in CASES {
        tracker: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker, context.allocator)
        alloc := mem.tracking_allocator(&tracker)

        r: term.Reader
        term.reader_init(&r, alloc)

        // Batch many copies per push so the measurement is decode, not syscall-shaped
        // push overhead.
        batch := strings.builder_make(context.allocator)
        defer strings.builder_destroy(&batch)
        per_push := 256
        for _ in 0 ..< per_push {
            strings.write_string(&batch, c.input)
        }

        bytes := transmute([]u8)strings.to_string(batch)

        // Warm the tail buffer so the steady-state number excludes first-push growth.
        _ = term.reader_push(&r, bytes)
        for {
            ev, err := term.reader_next(&r)
            if err != .None || ev == nil {
                break
            }
        }

        allocs_before := tracker.total_allocation_count

        rounds := TARGET_EVENTS / per_push
        events := 0
        start := time.tick_now()
        for _ in 0 ..< rounds {
            if term.reader_push(&r, bytes) != .None {
                break
            }

            for {
                ev, err := term.reader_next(&r)
                if err != .None || ev == nil {
                    break
                }

                events += 1
            }
        }

        elapsed := time.tick_since(start)
        allocs := tracker.total_allocation_count - allocs_before

        term.reader_destroy(&r)
        mem.tracking_allocator_destroy(&tracker)

        if events == 0 {
            fmt.printfln("%-20s  no events surfaced", c.name)
            continue
        }

        ns_event := f64(time.duration_nanoseconds(elapsed)) / f64(events)
        fmt.printfln(
            "%-20s %-10s %-10s %s",
            c.name,
            fmt.tprintf("%.1f", ns_event),
            fmt.tprintf("%.1f", 1000.0 / ns_event),
            fmt.tprintf("%d", allocs),
        )
    }
}

report_paste :: proc() {
    fmt.println("\n=== paste: the one allocating path ===")
    fmt.printfln("%-20s %-12s %-10s %s", "payload bytes", "ns/paste", "MB/s", "allocs")

    sizes := []int{64, 1024, 16 * 1024, 60 * 1024}
    for size in sizes {
        b := strings.builder_make(context.allocator)
        defer strings.builder_destroy(&b)
        strings.write_string(&b, "\x1b[200~")
        for strings.builder_len(b) < size {
            strings.write_string(&b, "lorem ipsum dolor sit amet ")
        }

        strings.write_string(&b, "\x1b[201~")
        bytes := transmute([]u8)strings.to_string(b)

        tracker: mem.Tracking_Allocator
        mem.tracking_allocator_init(&tracker, context.allocator)
        alloc := mem.tracking_allocator(&tracker)

        r: term.Reader
        term.reader_init(&r, alloc)

        // Warm both buffers to their high-water mark first.
        _ = term.reader_push(&r, bytes)
        for {
            ev, err := term.reader_next(&r)
            if err != .None || ev == nil {
                break
            }
        }

        allocs_before := tracker.total_allocation_count

        iterations := max(TARGET_EVENTS / max(size / 64, 1), 64)
        pasted := 0
        start := time.tick_now()
        for _ in 0 ..< iterations {
            if term.reader_push(&r, bytes) != .None {
                break
            }

            for {
                ev, err := term.reader_next(&r)
                if err != .None || ev == nil {
                    break
                }

                if p, ok := ev.(term.Paste); ok {
                    pasted += len(p.text)
                }
            }
        }

        elapsed := time.tick_since(start)
        allocs := tracker.total_allocation_count - allocs_before

        term.reader_destroy(&r)
        mem.tracking_allocator_destroy(&tracker)

        if pasted == 0 {
            fmt.printfln("%-20s  exceeds MAX_PUSH_BYTES, rejected by design", fmt.tprintf("%d", size))
            continue
        }

        ns_total := f64(time.duration_nanoseconds(elapsed))
        ns_paste := ns_total / f64(iterations)
        mb_s := f64(pasted) / (ns_total / 1e9) / (1024 * 1024)
        fmt.printfln(
            "%-20s %-12s %-10s %s",
            fmt.tprintf("%d", size),
            fmt.tprintf("%.1f", ns_paste),
            fmt.tprintf("%.1f", mb_s),
            fmt.tprintf("%d", allocs),
        )
    }
}
