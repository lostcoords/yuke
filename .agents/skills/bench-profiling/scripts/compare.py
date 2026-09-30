#!/usr/bin/env python3
"""Compare yuke bench phases between a base and a head, per iteration.

The default mode counts CPU instructions with callgrind. `--metrics` reads the
exact allocation counters of a `-Dmetrics=true` build instead. Each phase runs
at two iteration counts, and the table shows the slope between them, so the
one-time setup of a phase drops out.

Exit codes: 0 done, 2 bad arguments, 3 build failed, 4 bench run failed.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# The phases that draw or stream the transcript, plus boot: the usual gate.
DEFAULT_PHASES = [
    "build", "reflow", "scroll", "stream", "stream_native", "stream_tool", "stream_part",
    "paint", "colors", "selection", "preview", "chat_stream", "chat_frame", "boot",
]
# GC cycles land in a short window of these phases and move its slope by up to 20%, so they use a long window.
LONG_WINDOW = {"stream": (150, 300), "stream_native": (150, 300)}
# One boot iteration is a whole host boot, so a short window is enough.
BOOT_WINDOW = (5, 25)
DEFAULT_WINDOW = (10, 60)
# The bench repeats each phase this many times per run, and callgrind counts all repeats.
BENCH_REPEATS = 5
# The heaviest gate run (stream_native, 300 iterations) peaked at 622 MB under callgrind on 2026-09-30.
RUN_MEMORY = 1 << 30
# That run took 6 to 8 minutes with every core busy, so 30 minutes means a stuck run, not a slow one.
RUN_TIMEOUT = 30 * 60


def default_jobs():
    cpus = os.cpu_count() or 4
    try:
        with open("/proc/meminfo") as f:
            available = next(int(l.split()[1]) * 1024 for l in f if l.startswith("MemAvailable:"))
    except (OSError, StopIteration, ValueError):
        return cpus
    return max(1, min(cpus, available // RUN_MEMORY))


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def fail(code, msg):
    log("error: " + msg)
    sys.exit(code)


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()


def build_flags(metrics, valgrind):
    if metrics:
        return ["-Doptimize=ReleaseFast", "-Dmetrics=true"]
    # valgrind cannot decode the pointer-auth instructions of a native arm64 build, so callgrind needs a baseline CPU.
    flags = ["-Doptimize=ReleaseFast", "-Dcpu=baseline"]
    # Client requests also slow some std searches under valgrind, so both sides take the option or neither does.
    return flags + (["-Dvalgrind=true"] if valgrind else [])


def tree_name(side, tree):
    return side + "-" + re.sub(r"[^A-Za-z0-9]+", "-", str(tree)).strip("-")[-60:]


def install(src, dst):
    # A rename keeps the old inode for a run that still executes it, so parallel comparisons never see a half-written binary.
    tmp = dst.with_suffix(".tmp")
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def build(tree, out_dir, metrics, valgrind):
    """Build yuke-bench from `tree` into `out_dir`; answer the binary path and whether it has the valgrind option."""
    out_dir.mkdir(parents=True, exist_ok=True)
    binary = out_dir / "yuke-bench"
    flags = build_flags(metrics, valgrind)
    step = subprocess.run(["zig", "build", *flags, "bench-install", "-p", str(out_dir / "prefix")], cwd=tree, capture_output=True, text=True)
    if step.returncode == 0:
        install(out_dir / "prefix" / "bin" / "yuke-bench", binary)
        return binary, valgrind
    # A tree older than the bench-install step or the valgrind option: build by a one-iteration run, then take the newest binary.
    if "bench-install" not in step.stderr and "valgrind" not in step.stderr:
        log(step.stderr[-3000:])
        fail(3, f"zig build failed in {tree}")
    flags = [f for f in flags if f != "-Dvalgrind=true"]
    log(f"note: {tree} has no bench-install step or -Dvalgrind option; both sides build without it, and --region does not work")
    run = subprocess.run(["zig", "build", *flags, "bench", "--", "--phase", "boot", "--iterations", "1"], cwd=tree, capture_output=True, text=True)
    if run.returncode != 0:
        log(run.stderr[-3000:])
        fail(3, f"zig build bench failed in {tree}")
    found = sorted((tree / ".zig-cache" / "o").glob("*/yuke-bench"), key=lambda p: p.stat().st_mtime)
    if not found:
        fail(3, f"no yuke-bench binary in {tree}/.zig-cache")
    install(found[-1], binary)
    return binary, False


def prepare_base(repo, base, work, metrics):
    """Answer the base binary. A directory builds as it is; a git ref builds once per commit and the result stays cached."""
    variant = "metrics" if metrics else "callgrind"
    path = Path(base)
    if path.is_dir():
        return build(path.resolve(), work / "bin" / f"{tree_name('base', path.resolve())}-{variant}", metrics, not metrics)
    try:
        sha = git(repo, "rev-parse", "--verify", base + "^{commit}")
    except subprocess.CalledProcessError:
        fail(2, f"--base {base!r} is neither a directory nor a git commit")
    cached = work / "bin" / f"{sha[:12]}-{variant}"
    marker = cached / "regions"
    if (cached / "yuke-bench").exists() and marker.exists():
        log(f"base {sha[:12]}: cached build")
        return cached / "yuke-bench", marker.read_text() == "yes"
    tree = work / f"worktree-{sha[:12]}"
    if tree.exists():
        subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(tree)], capture_output=True)
    git(repo, "worktree", "add", "--detach", str(tree), sha)
    try:
        log(f"base {sha[:12]}: building (a few minutes)")
        binary, regions = build(tree, cached, metrics, not metrics)
        marker.write_text("yes" if regions else "no")
        return binary, regions
    finally:
        subprocess.run(["git", "-C", str(repo), "worktree", "remove", "--force", str(tree)], capture_output=True)


def window(phase, override):
    if override:
        return override
    if phase == "boot":
        return BOOT_WINDOW
    return LONG_WINDOW.get(phase, DEFAULT_WINDOW)


def run(cmd, cwd, timeout):
    try:
        return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        fail(4, f"run took over {timeout} s: {' '.join(cmd)}")


def run_callgrind(side, binary, cwd, fixture, phase, n, region, keep, timeout):
    # The region label is part of the name, so two region runs can share one --keep directory.
    out = str(keep / f"{side}-{phase}-{n}{'-' + region if region else ''}.cg") if keep else "/dev/null"
    cmd = ["valgrind", "--tool=callgrind", "--callgrind-out-file=" + out]
    if region:
        cmd.append("--collect-atstart=no")
    cmd += [str(binary), "--fixture", fixture, "--phase", phase, "--iterations", str(n)]
    if region:
        cmd += ["--region", region]
    proc = run(cmd, cwd, timeout)
    found = re.search(r"Collected : (\d+)", proc.stderr)
    if proc.returncode != 0 or not found:
        log(proc.stderr[-2000:])
        fail(4, f"callgrind run failed: {' '.join(cmd)}")
    return int(found.group(1))


def run_metrics(binary, cwd, fixture, phase, n, timeout):
    cmd = [str(binary), "--fixture", fixture, "--phase", phase, "--iterations", str(n)]
    proc = run(cmd, cwd, timeout)
    lines = [l for l in proc.stdout.splitlines() if l.startswith("{")]
    if proc.returncode != 0 or not lines:
        log(proc.stderr[-2000:])
        fail(4, f"bench run failed: {' '.join(cmd)}")
    # The last repeat has a warm process, as the other runs of the gate do.
    record = json.loads(lines[-1])
    if not record.get("metrics"):
        fail(4, "the bench build has no metrics; it needs -Dmetrics=true")
    return record


def pct(base, head):
    return (head - base) / base * 100 if base else float("nan")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", default="HEAD", help="git ref or directory of the base tree (default: HEAD)")
    parser.add_argument("--head", default=None, help="directory of the head tree (default: the repo working tree, with uncommitted edits)")
    parser.add_argument("--phases", default=",".join(DEFAULT_PHASES), help="comma-separated bench phases (default: the transcript gate plus boot)")
    parser.add_argument("--window", default=None, help="LO:HI iteration counts for every phase (default: per phase, see LONG_WINDOW)")
    parser.add_argument("--confirm", action="store_true", help="also run 2*HI and print the HI->2*HI slope, to tell a GC window from a real delta")
    parser.add_argument("--metrics", action="store_true", help="compare allocations and peak bytes of a -Dmetrics=true build instead of instructions")
    parser.add_argument("--region", default=None, help="count only the benchRegion(LABEL) probes of both trees")
    parser.add_argument("--keep", default=None, help="directory for the callgrind.out files, for fndiff.py")
    parser.add_argument("--fixture", default="bench/transcript-fixture.json", help="fixture path, relative to each tree")
    parser.add_argument("--jobs", type=int, default=default_jobs(), help="parallel runs (default: CPU count, capped at 1 GiB of available memory per run)")
    parser.add_argument("--timeout", type=int, default=RUN_TIMEOUT, help=f"seconds before one run counts as stuck (default: {RUN_TIMEOUT})")
    parser.add_argument("--work", default=None, help="cache directory for builds (default: $TMPDIR/yuke-bench-profiling)")
    args = parser.parse_args()

    if args.metrics and (args.region or args.keep):
        fail(2, "--metrics does not take --region or --keep")
    for tool in (["zig", "git"] + ([] if args.metrics else ["valgrind"])):
        if not shutil.which(tool):
            fail(2, f"{tool} is not on PATH")
    try:
        repo = Path(subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip())
    except subprocess.CalledProcessError:
        fail(2, "run this inside the yuke repo")
    head_tree = Path(args.head).resolve() if args.head else repo
    work = Path(args.work or os.path.join(os.environ.get("TMPDIR", "/tmp"), "yuke-bench-profiling")).resolve()
    keep = Path(args.keep).resolve() if args.keep else None
    if keep:
        keep.mkdir(parents=True, exist_ok=True)
    override = None
    if args.window:
        lo, _, hi = args.window.partition(":")
        if not (lo.isdigit() and hi.isdigit() and 0 < int(lo) < int(hi)):
            fail(2, "--window takes LO:HI with 0 < LO < HI")
        override = (int(lo), int(hi))
    phases = [p for p in args.phases.split(",") if p]

    base_bin, base_regions = prepare_base(repo, args.base, work, args.metrics)
    log("head: building")
    # Each head tree has its own build directory, so two comparisons can run at the same time.
    head_variant = "metrics" if args.metrics else ("callgrind" if base_regions else "callgrind-plain")
    head_bin, head_regions = build(head_tree, work / "bin" / f"{tree_name('head', head_tree)}-{head_variant}", args.metrics, base_regions and not args.metrics)
    if args.region and not (base_regions and head_regions):
        fail(2, "--region needs the -Dvalgrind option on both sides; use --base with a directory that has it")
    # A base from a git ref has no tree left after its build, so it reads the fixture from the repo.
    sides = {"base": (base_bin, Path(args.base).resolve() if Path(args.base).is_dir() else repo), "head": (head_bin, head_tree)}

    jobs = []
    for phase in phases:
        lo, hi = window(phase, override)
        counts = [lo, hi] + ([2 * hi] if args.confirm else [])
        for side in sides:
            for n in counts:
                jobs.append((side, phase, n))
    log(f"running {len(jobs)} bench runs on {args.jobs} jobs")
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {}
        for side, phase, n in jobs:
            binary, tree = sides[side]
            # The fixture path is relative to the tree, so each side reads its own copy.
            if args.metrics:
                futures[pool.submit(run_metrics, binary, tree, args.fixture, phase, n, args.timeout)] = (side, phase, n)
            else:
                futures[pool.submit(run_callgrind, side, binary, tree, args.fixture, phase, n, args.region, keep, args.timeout)] = (side, phase, n)
        for done in concurrent.futures.as_completed(futures):
            results[futures[done]] = done.result()

    if args.metrics:
        print("| phase | window | allocs/it base | allocs/it head | Δ | peak KB base | peak KB head | Δ | JS heap KB base | JS heap KB head | Δ |")
        print("|---|---|---|---|---|---|---|---|---|---|---|")
        for phase in phases:
            lo, hi = window(phase, override)
            row = {}
            for side in sides:
                a, b = results[(side, phase, lo)], results[(side, phase, hi)]
                row[side] = ((b["allocations"]["allocations"] - a["allocations"]["allocations"]) / (hi - lo), b["backing_peak_bytes"] / 1024, b["js_tracked_bytes"] / 1024)
            B, H = row["base"], row["head"]
            print(f"| {phase} | {lo}→{hi} | {B[0]:.2f} | {H[0]:.2f} | {H[0] - B[0]:+.2f} | {B[1]:,.0f} | {H[1]:,.0f} | {pct(B[1], H[1]):+.1f}% | {B[2]:,.0f} | {H[2]:,.0f} | {pct(B[2], H[2]):+.1f}% |")
        print(f"\nallocs/it: backing allocations per iteration (exact). peak and JS heap: bytes at the high count; GC timing moves them, so rerun a phase at other counts before you call a delta real.")
        return

    what = f"region `{args.region}`" if args.region else "whole phase"
    print(f"| phase | window | base instr/it | head instr/it | Δ |" + (" Δ (confirm) |" if args.confirm else ""))
    print("|---|---|---|---|---|" + ("---|" if args.confirm else ""))
    for phase in phases:
        lo, hi = window(phase, override)
        slope = {s: (results[(s, phase, hi)] - results[(s, phase, lo)]) / (hi - lo) for s in sides}
        line = f"| {phase} | {lo}→{hi} | {slope['base']:,.0f} | {slope['head']:,.0f} | {pct(slope['base'], slope['head']):+.2f}% |"
        if args.confirm:
            second = {s: (results[(s, phase, 2 * hi)] - results[(s, phase, hi)]) / hi for s in sides}
            line += f" {pct(second['base'], second['head']):+.2f}% |"
        print(line)
    print(f"\ninstr/it: callgrind instructions per iteration of the {what}, summed over the bench's {BENCH_REPEATS} repeats. Negative Δ is less work.")
    if keep:
        print(f"callgrind files: {keep} (<side>-<phase>-<n>[-<region>].cg); diff them with fndiff.py.")


if __name__ == "__main__":
    main()
