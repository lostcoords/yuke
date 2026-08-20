#+build !windows
package js

import "core:c"
import "core:strings"
import "core:sys/posix"

// A spawned command, named by the process group it leads. `posix_spawn` sets the group before
// the child execs, so signalling the group can never race the spawn.
Exec_Process :: struct {
    pid: posix.pid_t,
}

// The working directory arrives as an argument rather than inside the script, so a directory
// holding a quote or a space needs no escaping. `posix_spawn` has no portable chdir action:
// `addchdir_np` is absent on musl before 1.2.3 and on glibc before 2.29.
@(private = "file")
EXEC_CWD_SCRIPT :: `cd -- "$1" || exit 126; eval "$2"`

@(private = "file")
EXEC_SHELL :: "/bin/sh"

// Spawn the shell in its own process group with both pipes attached and stdin on /dev/null.
// Nothing here is contained: a shell command can leave any directory we pin, so a check would
// buy the appearance of safety rather than safety. An embedder gates the caller instead.
exec_spawn :: proc(job: ^Exec_Job, stdout_w: posix.FD, stderr_w: posix.FD) -> (Exec_Process, bool) {
    assert(job != nil, "a spawn needs job state")
    assert(stdout_w >= 0 && stderr_w >= 0, "a spawn needs both pipes")

    command, command_err := strings.clone_to_cstring(job.command, job.allocator)
    if command_err != nil do return {}, false

    // `sh -c <script> <name> <args...>` binds $0 to the name, so the directory is $1 and the
    // command is $2. A trailing nil terminates argv.
    args: [7]cstring
    args = {"sh", "-c", command, nil, nil, nil, nil}

    if job.cwd != "" {
        cwd, cwd_err := strings.clone_to_cstring(job.cwd, job.allocator)
        if cwd_err != nil do return {}, false

        args = {"sh", "-c", EXEC_CWD_SCRIPT, "sh", cwd, command, nil}
    }

    actions: Spawn_File_Actions
    if posix_spawn_file_actions_init(&actions) != .NONE do return {}, false

    defer posix_spawn_file_actions_destroy(&actions)

    attr: Spawn_Attr
    if posix_spawnattr_init(&attr) != .NONE do return {}, false

    defer posix_spawnattr_destroy(&attr)

    // Its own group leader: pgroup 0 makes the child's group id its own pid, which is what
    // lets one signal reach the shell and everything the shell starts.
    if posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP) != .NONE do return {}, false

    if posix_spawnattr_setpgroup(&attr, 0) != .NONE do return {}, false

    // A command must not read the daemon's stdin, so it gets /dev/null rather than a copy.
    if posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", {}, {}) != .NONE do return {}, false

    if posix_spawn_file_actions_adddup2(&actions, stdout_w, 1) != .NONE do return {}, false

    if posix_spawn_file_actions_adddup2(&actions, stderr_w, 2) != .NONE do return {}, false

    process: Exec_Process
    if posix.posix_spawn(&process.pid, EXEC_SHELL, &actions, &attr, raw_data(args[:]), posix.environ) != .NONE do return {}, false

    return process, true
}

exec_signal_group :: proc(process: Exec_Process, sig: posix.Signal) {
    assert(process.pid > 0, "signalling a command needs a live process")

    // The child leads its own group, so its pid is the group id.
    _ = posix.killpg(process.pid, sig)
}

// `posix_spawnattr_t` and `posix_spawn_file_actions_t` are opaque with an implementation-
// defined size: glibc needs 336 and 80 bytes, darwin stores one pointer. This buffer is larger
// than any of them and pointer-aligned. `init` writes only its real size and neither object is
// ever copied by value, so the spare room is harmless.
@(private = "file")
Spawn_Attr :: distinct [64]uintptr

@(private = "file")
Spawn_File_Actions :: distinct [64]uintptr

@(private = "file")
POSIX_SPAWN_SETPGROUP :: c.short(0x02)

when ODIN_OS == .Darwin {
    foreign import libc_ "system:System.framework"
} else {
    foreign import libc_ "system:c"
}

// `core:sys/posix` binds `posix_spawn` with untyped attributes, so the objects it takes have
// no constructors there.
@(private = "file")
foreign libc_ {
    posix_spawnattr_init :: proc(attr: ^Spawn_Attr) -> posix.Errno ---
    posix_spawnattr_destroy :: proc(attr: ^Spawn_Attr) -> posix.Errno ---
    posix_spawnattr_setflags :: proc(attr: ^Spawn_Attr, flags: c.short) -> posix.Errno ---
    posix_spawnattr_setpgroup :: proc(attr: ^Spawn_Attr, pgroup: posix.pid_t) -> posix.Errno ---
    posix_spawn_file_actions_init :: proc(actions: ^Spawn_File_Actions) -> posix.Errno ---
    posix_spawn_file_actions_destroy :: proc(actions: ^Spawn_File_Actions) -> posix.Errno ---
    posix_spawn_file_actions_adddup2 :: proc(actions: ^Spawn_File_Actions, fd: posix.FD, newfd: posix.FD) -> posix.Errno ---
    posix_spawn_file_actions_addopen :: proc(actions: ^Spawn_File_Actions, fd: posix.FD, path: cstring, flags: posix.O_Flags, mode: posix.mode_t) -> posix.Errno ---
}
