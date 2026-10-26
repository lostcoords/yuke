#!/usr/bin/env python3
"""Measure coding agents at rest: startup time, idle memory, idle CPU, and binary size.

Usage: tools/bench-idle.py [--runs N] [--idle SECONDS] NAME=COMMAND ...

Each run starts COMMAND in a detached 160x45 tmux pane in a new empty directory. Startup is
the time until the screen stops changing for STABLE seconds. Memory is the RSS of the
process tree after the idle window, and CPU is the time the tree used during that window.
The script prints one Markdown row per agent with the median of the runs, and saves the
last screen of each agent next to the results, so a reader can check where it stopped.
macOS and Linux need tmux and ps. The script makes no network requests itself.
"""

import argparse
import os
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

STABLE = 1.0
POLL = 0.02
TIMEOUT = 30.0


def tmux(*args):
    return subprocess.run(["tmux", *args], check=True, capture_output=True, text=True).stdout


def tree(root):
    """Return the PIDs of root and all of its descendants."""
    table = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], check=True, capture_output=True, text=True).stdout
    children = {}
    for line in table.splitlines():
        pid, ppid = (int(field) for field in line.split())
        children.setdefault(ppid, []).append(pid)
    found, stack = [], [root]
    while stack:
        pid = stack.pop()
        found.append(pid)
        stack.extend(children.get(pid, []))
    return found


def cpu_time(text):
    """Convert ps TIME, [[dd-]hh:]mm:ss.cc, to seconds."""
    days, _, clock = text.rpartition("-")
    seconds = 0.0
    for part in clock.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds + (int(days) * 86400 if days else 0)


def usage(root):
    """Return the total RSS in KiB and CPU seconds of the process tree under root."""
    pids = ",".join(str(pid) for pid in tree(root))
    result = subprocess.run(["ps", "-o", "rss=,time=", "-p", pids], capture_output=True, text=True)
    rss = cpu = 0.0
    for line in result.stdout.splitlines():
        kib, clock = line.split()
        rss += int(kib)
        cpu += cpu_time(clock)
    return rss, cpu


def run(name, command, idle, output):
    workspace = tempfile.mkdtemp(prefix="bench-")
    session = f"bench-{name}-{os.getpid()}"
    started = time.monotonic()
    tmux("new-session", "-d", "-s", session, "-x", "160", "-y", "45", "-c", workspace, command)
    try:
        screen, changed = "", started
        while time.monotonic() - started < TIMEOUT:
            current = tmux("capture-pane", "-p", "-t", session)
            now = time.monotonic()
            if current != screen:
                screen, changed = current, now
            elif screen.strip() and now - changed >= STABLE:
                break
            time.sleep(POLL)
        startup = changed - started
        root = int(tmux("display-message", "-p", "-t", session, "#{pane_pid}").strip())
        _, before = usage(root)
        time.sleep(idle)
        rss, after = usage(root)
        (output / f"{name}.screen.txt").write_text(tmux("capture-pane", "-p", "-t", session))
        return startup, rss / 1024, after - before
    finally:
        subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)
        shutil.rmtree(workspace, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--idle", type=float, default=30.0)
    parser.add_argument("--output", type=Path, default=Path("target/bench"))
    parser.add_argument("agents", nargs="+", metavar="NAME=COMMAND")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    print("| Agent | Startup | Idle memory | Idle CPU per minute | Binary |")
    print("|---|---|---|---|---|")
    for agent in args.agents:
        name, _, command = agent.partition("=")
        results = [run(name, command, args.idle, args.output) for _ in range(args.runs)]
        startup, memory, cpu = (statistics.median(column) for column in zip(*results))
        binary = Path(shutil.which(command.split()[0]) or command.split()[0]).resolve()
        size = binary.stat().st_size / 1_000_000
        print(f"| {name} | {startup:.2f} s | {memory:.1f} MiB | {cpu * 60 / args.idle:.2f} s | {size:.0f} MB |")


if __name__ == "__main__":
    main()
