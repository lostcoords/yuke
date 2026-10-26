---
description: Startup time, idle memory, idle CPU, and binary size of yuke and other terminal coding agents, with the method and the script.
---

# Benchmarks

yuke is one native binary with no runtime. This page compares it at rest with other terminal coding agents.

## Results

| Agent | Startup | Idle memory | Idle CPU per minute | Binary |
|---|---|---|---|---|
| yuke | 0.06 s | 12.5 MiB | 0.00 s | 16 MB |
| Claude Code 2.1.310 | 0.50 s | 188.9 MiB | 0.40 s | 274 MB |
| Codex 0.164.0 | 1.50 s | 257.4 MiB | 0.84 s | 260 MB |
| OpenCode 1.18.10 | 3.47 s | 1231.5 MiB | 1.66 s | 139 MB |

The yuke row is the current `main` build. Its terminal UI does not show the chat yet, so its memory can grow as the chat lands. For reference, the earlier Zig build of yuke, with the full chat, used 14.4 MiB at idle and reached its first screen in 0.08 s.

## Method

Measured on 2026-10-26 on an Apple M2 Pro with macOS 26.6.

- Each agent starts in a new empty directory, in a detached tmux pane of 160 by 45 cells.
- **Startup** is the time from launch until the screen stops changing for one second.
- **Idle memory** is the resident memory of the agent's whole process tree after 30 seconds at its first screen.
- **Idle CPU** is the processor time that the process tree used during those 30 seconds, scaled to one minute.
- **Binary** is the size of the installed executable.
- Each value is the median of three runs.

No agent sent a prompt. The first screen differs between agents: Claude Code asked whether to trust the directory, and OpenCode offered an update. Each run saves the last screen next to the results, so you can check where each agent stopped.

## Run it yourself

The script is [`tools/bench-idle.py`](https://github.com/lostcoords/yuke/blob/site/tools/bench-idle.py) in the repository. It needs Python 3 and tmux.

```sh
python3 tools/bench-idle.py yuke=target/release/yuke "Claude Code=claude" Codex=codex OpenCode=opencode
```

It prints the table above. Use `--runs` and `--idle` to change the number of runs and the length of the idle window.
