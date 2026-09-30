---
name: bench-profiling
description: Profiles yuke bench phases with callgrind to find why a phase is slower or allocates more than a base commit, and to prove that a hot-path change costs nothing. Use when a `zig build bench` phase is worse than base, before a commit that touches draw, input, stream delivery, per-frame, or per-row code, when cost hides inside QuickJS (`JS_CallInternal`), or when asked to compare performance or memory against a commit.
---

# Bench profiling

The bench (`zig build bench`, `src/js/bench/`) holds the workloads. The scripts here run it under callgrind on a base and a head, and turn the output into a per-iteration table. Callgrind counts instructions exactly, so a 0.3% delta is real; wall time on the dev machine moves by about 20%.

Needs `valgrind`, `python3`, `zig`, and `git` on `PATH`. Run the scripts from the repo root. Each script has `--help`.

## Steps

1. **Measure.** Compare the head (the working tree, with uncommitted edits) against a base commit:
   ```
   python3 .agents/skills/bench-profiling/scripts/compare.py --base <commit>
   ```
   A base build takes a few minutes and stays cached per commit. Add `--phases a,b` to run fewer phases. Before you call a small delta real, run the phase again with `--confirm`: it adds a second window.

2. **Memory.** The same comparison for allocations and peak bytes:
   ```
   python3 .agents/skills/bench-profiling/scripts/compare.py --base <commit> --metrics
   ```

3. **Split native, JS, and GC.** Keep the profiles of one phase, then diff the slopes by function:
   ```
   python3 .agents/skills/bench-profiling/scripts/compare.py --base <commit> --phases <p> --keep /tmp/bp
   python3 .agents/skills/bench-profiling/scripts/fndiff.py /tmp/bp/base-<p>-<lo>.cg /tmp/bp/base-<p>-<hi>.cg /tmp/bp/head-<p>-<lo>.cg /tmp/bp/head-<p>-<hi>.cg --per <hi-lo>
   ```
   - A named Zig or C function that moved is the answer for native code.
   - If the `GC` line holds most of the delta, the window caught a GC cycle. Use `--confirm` or another window.
   - `JS_CallInternal` or `JS_GetPropertyInternal` means interpreted JS: go to step 4.

4. **See inside the interpreter.** Group the `JS_CallInternal` cost by opcode:
   ```
   python3 .agents/skills/bench-profiling/scripts/fndiff.py <the same four files> --per <hi-lo> --opcodes
   ```
   - `(prologue)`, `(epilogue)`, and `OP_set_loc_uninitialized` grow: a called function has more locals. See "Call cost: locals" in `references/quickjs.md`.
   - `js_clone_shape`, `add_property`, or `memcpy` grow in the function diff: objects change shape. See "Object shapes".
   - One opcode grows: find the JS that runs it more often.

5. **Find the JS.** Count one region of code:
   1. Copy each tree to a scratch directory. Never put a probe in the user's tree:
      ```
      rsync -a --exclude=.zig-cache --exclude=zig-out --exclude=.git <tree>/ <scratch>/<name>/
      ```
      For the base, make a `git worktree` of the commit and copy it, then remove the worktree.
   2. In both copies, put a probe pair around the same code: `globalThis.benchRegion?.("x");` before and after. The optional call keeps a `-Dmetrics` build working.
   3. Run `compare.py --base <scratch>/base --head <scratch>/head --region x --phases <p> --keep /tmp/bpr`. Both trees must have the `-Dvalgrind` build option (commits after 2026-09-30).
   4. Narrow the region until one change explains the delta. Run `fndiff.py` on the kept files to see which C functions moved inside it.
   - Regions do not nest: an inner pair with another label counts inside the outer region. To count one plugin callback without its nested callbacks, pause the outer label around the nested calls.
   - `benchRegion` exists in every host of the bench, also in the fresh host of each `boot` iteration.

6. **Fix and prove.** Run step 1 again on the phases you changed. Add the finding with its numbers to the log in `references/quickjs.md`. Add a one-line rule to the QuickJS list in `AGENTS.md` if it applies to other code.

## Reading the numbers

- `instr/it` is instructions per iteration, summed over the 5 repeats of each bench run. The percent is exact. The absolute number is 5 times one iteration.
- The slope between two iteration counts drops the one-time setup. Totals of a short run are mostly setup, so never compare totals.
- `stream` and `stream_native` use 150→300 by default, because GC cycles move shorter windows by 20% or more. `boot` uses 5→25; one boot iteration is a whole host boot.
- `allocs/it` counts backing allocations: QuickJS arena blocks and native buffers, not JS objects. Peak and JS heap bytes move with GC timing; check another count before you trust a peak delta.
- A small delta can come from heap layout, not code. See "Object shapes" in `references/quickjs.md` for the long-lived `{}` case. Name such a delta a bench artifact only with evidence.

## Rules

- Do not edit the user's tree for a probe. Probes live in scratch copies. Before a commit, run `git grep -n benchRegion -- src` and expect no hits outside `src/js/bench/bench.zig`.
- Do not `git checkout` a dirty file to drop a probe. Delete the scratch copy.
- Stop a run by its PID, not with `pkill -f` on text that is also in your own command line.
- If a phase is worse and you cannot fix it, stop and report the table and the cause (AGENTS.md).
