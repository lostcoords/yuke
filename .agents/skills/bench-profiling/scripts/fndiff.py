#!/usr/bin/env python3
"""Diff the self cost of two callgrind profiles by function, or by QuickJS opcode.

Two files diff their totals: fndiff.py BASE.cg HEAD.cg
Four files diff the slope between two iteration counts, so setup drops out:
    fndiff.py BASE_LO.cg BASE_HI.cg HEAD_LO.cg HEAD_HI.cg

Functions merge by name across trees and recursion levels (`JS_CallInternal'2`
counts as `JS_CallInternal`), so the two sides may come from different checkouts.
`--opcodes` groups the self cost of JS_CallInternal by the `CASE(OP_...)` line
in quickjs.c above each costed line. Inlined helpers blur this, so treat it as a
histogram, not an exact count.

Exit codes: 0 done, 2 bad arguments or unreadable profile.
"""

import argparse
import bisect
import re
import sys
from collections import defaultdict
from pathlib import Path

# The collector and its helpers; a heap layout change moves these without a code change.
GC_NAMES = re.compile(r"(RunGC|_mark\b|_mark$|^gc_|mark_children|free_gc_object|free_zero_refcount|gc_decref|gc_scan)")
RECURSION = re.compile(r"'\d+$")
NAMED = re.compile(r"^\((\d+)\)(?: (.*))?$")


def fail(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(2)


def parse(path):
    """Answer (self cost by function, self cost by (file, line) of JS_CallInternal, event name)."""
    names = {"fn": {}, "file": {}}
    by_fn = defaultdict(int)
    by_line = defaultdict(int)
    fn = file = None
    last_pos = 0
    skip_next = False
    events = None
    try:
        lines = open(path, encoding="utf-8", errors="replace")
    except OSError as e:
        fail(f"cannot read {path}: {e}")

    def resolve(space, value):
        m = NAMED.match(value)
        if not m:
            return value
        if m.group(2) is not None:
            names[space][m.group(1)] = m.group(2)
        return names[space].get(m.group(1), value)

    with lines:
        for line in lines:
            line = line.rstrip("\n")
            if not line:
                continue
            head = line[0]
            if head.isdigit() or head in "+-*":
                parts = line.split()
                pos = parts[0]
                if pos == "*":
                    cur = last_pos
                elif pos[0] in "+-":
                    cur = last_pos + int(pos)
                else:
                    cur = int(pos)
                last_pos = cur
                # The line after `calls=` holds the inclusive cost of that call, not self cost.
                if skip_next:
                    skip_next = False
                    continue
                cost = int(parts[1]) if len(parts) > 1 else 0
                by_fn[fn] += cost
                if fn == "JS_CallInternal" and file and file.endswith("quickjs.c"):
                    by_line[cur] += cost
                continue
            key, _, value = line.partition("=")
            if line.startswith("positions:"):
                # With `--dump-instr=yes` a cost line starts with an address, so the second field is no longer the cost.
                if line.split(":", 1)[1].split() != ["line"]:
                    fail(f"{path}: positions are {line.split(':', 1)[1].strip()}; record with the default positions, without --dump-instr")
            elif key == "events" or line.startswith("events:"):
                events = line.split(":", 1)[1].split()
            elif key == "fn":
                fn = RECURSION.sub("", resolve("fn", value))
            elif key in ("cfn",):
                resolve("fn", value)
            elif key in ("fl", "fi", "fe"):
                file = resolve("file", value)
            elif key in ("cfi", "cfl", "cob", "ob"):
                if key != "ob" and key != "cob":
                    resolve("file", value)
            elif key == "calls":
                skip_next = True
    if events and events[0] != "Ir":
        fail(f"{path}: the first event is {events[0]}, not Ir")
    return by_fn, by_line


def opcode_map(quickjs_c):
    """Answer a list of (line, opcode) for each `CASE(OP_...)` line of quickjs.c, in line order."""
    marks = []
    try:
        with open(quickjs_c, encoding="utf-8", errors="replace") as f:
            for n, text in enumerate(f, 1):
                for op in re.findall(r"CASE\((OP_\w+)\)", text):
                    marks.append((n, op))
                # The code after the dispatch switch frees every local on return, so it costs more with more locals.
                if marks and text.strip() == "exception:" and marks[-1][1] != "(epilogue)":
                    marks.append((n, "(epilogue)"))
    except OSError as e:
        fail(f"cannot read {quickjs_c}: {e}")
    if not marks:
        fail(f"{quickjs_c} has no CASE(OP_...) lines")
    return marks


def by_opcode(by_line, marks):
    starts = [m[0] for m in marks]
    out = defaultdict(int)
    for line, cost in by_line.items():
        i = bisect.bisect_right(starts, line) - 1
        # Lines above the first CASE are the call prologue: frame setup and local initialization.
        out[marks[i][1] if i >= 0 else "(prologue)"] += cost
    return out


def find_quickjs():
    here = Path(__file__).resolve()
    for root in here.parents:
        found = sorted(root.glob("zig-pkg/*/quickjs.c"))
        if found:
            return found[0]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", help="2 files (base head) or 4 files (base_lo base_hi head_lo head_hi)")
    parser.add_argument("--top", type=int, default=25, help="rows to print (default: 25)")
    parser.add_argument("--opcodes", action="store_true", help="group JS_CallInternal self cost by QuickJS opcode")
    parser.add_argument("--quickjs", default=None, help="path of quickjs.c for --opcodes (default: the vendored copy)")
    parser.add_argument("--per", type=float, default=1.0, help="divide the costs by this, e.g. the iteration difference")
    args = parser.parse_args()
    if len(args.files) not in (2, 4):
        fail("give 2 files (base head) or 4 files (base_lo base_hi head_lo head_hi)")

    parsed = [parse(p) for p in args.files]
    if args.opcodes:
        src = args.quickjs or find_quickjs()
        if not src:
            fail("no quickjs.c found; pass --quickjs")
        marks = opcode_map(src)
        tables = [by_opcode(lines, marks) for _, lines in parsed]
    else:
        tables = [fns for fns, _ in parsed]

    if len(tables) == 2:
        base, head = tables
    else:
        keys = set().union(*tables)
        base = {k: tables[1].get(k, 0) - tables[0].get(k, 0) for k in keys}
        head = {k: tables[3].get(k, 0) - tables[2].get(k, 0) for k in keys}
    keys = set(base) | set(head)
    rows = sorted(((head.get(k, 0) - base.get(k, 0), base.get(k, 0), head.get(k, 0), k) for k in keys), key=lambda r: -abs(r[0]))
    label = "opcode" if args.opcodes else "function"
    per = args.per
    print(f"| {label} | base | head | Δ |")
    print("|---|---|---|---|")
    for d, b, h, k in rows[: args.top]:
        print(f"| {k} | {b / per:,.0f} | {h / per:,.0f} | {d / per:+,.0f} |")
    tb, th = sum(base.values()), sum(head.values())
    print(f"\ntotal: base {tb / per:,.0f}  head {th / per:,.0f}  Δ {(th - tb) / per:+,.0f}" + (f" ({(th - tb) / tb * 100:+.2f}%)" if tb else ""))
    if not args.opcodes:
        gb = sum(v for k, v in base.items() if k and GC_NAMES.search(k))
        gh = sum(v for k, v in head.items() if k and GC_NAMES.search(k))
        print(f"GC:    base {gb / per:,.0f}  head {gh / per:,.0f}  Δ {(gh - gb) / per:+,.0f}")
        print(f"other: base {(tb - gb) / per:,.0f}  head {(th - gh) / per:,.0f}  Δ {((th - gh) - (tb - gb)) / per:+,.0f}")


if __name__ == "__main__":
    main()
