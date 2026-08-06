package daemon

import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import wire "src:wire"

// Truncate `s` to at most `max` bytes, backing off to the previous UTF-8 rune boundary.
// Filesystem bytes are untrusted: non-UTF-8 input yields "" rather than an invalid frame.
clamp_utf8_bytes :: proc(s: string, max: int) -> string {
    assert(max >= 0, "clamp_utf8_bytes: max must be non-negative")

    if !utf8.valid_string(s) {
        return ""
    }

    if len(s) <= max {
        return s
    }

    cut := max
    for cut > 0 && s[cut] & 0xC0 == 0x80 {
        cut -= 1
    }

    return s[:cut]
}

// The directory's modification time in epoch ms, or 0 when it cannot be stat'd.
path_mtime_ms :: proc(path: string, allocator: mem.Allocator) -> u64 {
    assert(len(path) > 0, "path mtime needs a canonical path")

    info, err := os.stat(path, allocator)
    if err != nil {
        return 0
    }

    ns := time.to_unix_nanoseconds(info.modification_time)
    if ns < 0 {
        return 0
    }

    return u64(ns / 1_000_000)
}

// The parent-directory path of a canonicalized dir, or null at the filesystem root.
parent_dir :: proc(dir: string) -> Maybe(string) {
    assert(len(dir) > 0, "parent lookup needs a canonical directory")

    if dir == "/" {
        return nil
    }

    return os.dir(dir)
}

// List `dir`'s immediate subdirectories as `Dir_Entry`s, case-insensitively sorted,
// flagging git repos. Omits files, `.git`, names past the wire's 256-byte bound, and
// non-UTF-8 names or paths; follows symlinks. Errors only when `dir` itself can't read.
browse_entries :: proc(dir: string, allocator: mem.Allocator) -> (entries: []wire.Dir_Entry, err: os.Error) {
    assert(len(dir) > 0, "browse needs a canonicalized directory")

    infos := os.read_all_directory_by_path(dir, allocator) or_return

    out := make([dynamic]wire.Dir_Entry, 0, len(infos), allocator)
    for info in infos {
        if info.name == ".git" {
            continue
        }

        if len(info.name) > 256 {
            // Some filesystems (APFS) allow names up to ~1020 UTF-8 bytes, past the
            // wire's 256-byte bound; unrepresentable, so skipped rather than aborting.
            continue
        }

        if !utf8.valid_string(info.name) || !utf8.valid_string(info.fullpath) {
            // Filesystem bytes are untrusted: a non-UTF-8 name or path cannot ride a
            // WebSocket TEXT frame (RFC 6455 §5.6), so it is skipped, not emitted.
            continue
        }

        if !file_info_is_dir(info, allocator) {
            continue
        }

        append(
            &out,
            wire.Dir_Entry {
                name = info.name,
                path = info.fullpath,
                is_git_repo = os.exists(strings.concatenate({info.fullpath, "/.git"}, allocator)),
            },
        )
    }

    slice.sort_by(out[:], dir_entry_less)

    return out[:], nil
}

// Whether a directory entry resolves to a directory, following a symlink or an entry
// whose type the platform left undetermined.
file_info_is_dir :: proc(info: os.File_Info, allocator: mem.Allocator) -> bool {
    if info.type == .Directory {
        return true
    }

    if info.type == .Symlink || info.type == .Undetermined {
        resolved, err := os.stat(info.fullpath, allocator)
        return err == nil && resolved.type == .Directory
    }

    return false
}

// Case-insensitive name order for a browse listing (ASCII fold), matching the
// reference daemon's deterministic ordering.
dir_entry_less :: proc(a, b: wire.Dir_Entry) -> bool {
    an := a.name
    bn := b.name
    n := min(len(an), len(bn))

    for i in 0 ..< n {
        ca := ascii_lower(an[i])
        cb := ascii_lower(bn[i])
        if ca != cb {
            return ca < cb
        }
    }

    return len(an) < len(bn)
}

ascii_lower :: proc(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' {
        return c + 32
    }

    return c
}
