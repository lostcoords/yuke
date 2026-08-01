package daemon

import "core:hash"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import wire "src:wire"

// Derived workspace id: FNV-1a-64 over the canonical root's UTF-8 bytes, rendered as
// 16 lowercase hex chars. The same scheme the reference daemon uses, so a directory
// always maps to a stable id.
daemon_workspace_id :: proc(root: string) -> wire.Workspace_Id {
    assert(len(root) > 0, "workspace id needs a canonical root")

    h := hash.fnv64a(transmute([]byte)root)

    hex := "0123456789abcdef"
    out: [16]u8
    for i in 0 ..< 16 {
        out[i] = hex[(h >> uint((15 - i) * 4)) & 0xf]
    }

    id := wire.Workspace_Id(out)
    assert(wire.enforce_fixed_lower_hex(16, string(out[:])) == .None, "derived workspace id is invalid")

    return id
}

// Display title for a workspace: the canonical root's basename, falling back to the
// whole root when it has none (the filesystem root), clamped to the `Workspace.title`
// bound.
daemon_workspace_title :: proc(root: string) -> string {
    assert(len(root) > 0, "workspace title needs a canonical root")

    base := os.base(root)
    title := base
    if title == "" {
        title = root
    }

    return daemon_clamp_utf8_bytes(title, 256)
}

// Truncate `s` to at most `max` bytes, backing off to the previous UTF-8 rune
// boundary if `max` lands mid-rune. Keeps peer-influenceable strings (git ref
// names, filesystem basenames) within a wire byte bound. Filesystem bytes are
// untrusted: an input that is not valid UTF-8 yields "" so no caller can emit an
// invalid TEXT frame.
daemon_clamp_utf8_bytes :: proc(s: string, max: int) -> string {
    assert(max >= 0, "daemon_clamp_utf8_bytes: max must be non-negative")

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

// Git status for a workspace root: null when it is not a repo (no `.git`), else the
// branch parsed from `.git/HEAD`. Dirty detection needs the git binary, which this
// step deliberately avoids, so `dirty` is always reported false.
daemon_git_info :: proc(root: string, allocator: mem.Allocator) -> Maybe(wire.Git_Info) {
    assert(len(root) > 0, "git info needs a canonical root")

    git_marker := strings.concatenate({root, "/.git"}, allocator)
    if !os.exists(git_marker) {
        return nil
    }

    return wire.Git_Info{branch = daemon_git_branch(root, allocator), dirty = false}
}

// Current branch from `.git/HEAD`: the ref name for a symbolic HEAD, or "" for a
// detached, unreadable, or non-UTF-8 HEAD. Clamped to the `Git_Info.branch` bound.
daemon_git_branch :: proc(root: string, allocator: mem.Allocator) -> string {
    assert(len(root) > 0, "git branch needs a canonical root")

    head, err := os.read_entire_file_from_path(strings.concatenate({root, "/.git/HEAD"}, allocator), allocator)
    if err != nil {
        return ""
    }

    ref := strings.trim_space(string(head))
    PREFIX :: "ref: refs/heads/"
    if !strings.has_prefix(ref, PREFIX) {
        return ""
    }

    branch := ref[len(PREFIX):]

    return daemon_clamp_utf8_bytes(branch, 256)
}

// The directory's modification time in epoch ms, or 0 when it cannot be stat'd.
daemon_path_mtime_ms :: proc(path: string, allocator: mem.Allocator) -> u64 {
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
daemon_parent_dir :: proc(dir: string) -> Maybe(string) {
    assert(len(dir) > 0, "parent lookup needs a canonical directory")

    if dir == "/" {
        return nil
    }

    return os.dir(dir)
}

// List `dir`'s immediate subdirectories as `Dir_Entry`s, case-insensitively sorted,
// omitting files, the `.git` directory, names past the wire's 256-byte bound, and
// entries whose name or path is not valid UTF-8, and flagging git repos. Symlinks are
// followed. Errors only when the directory itself cannot be read.
daemon_browse_entries :: proc(dir: string, allocator: mem.Allocator) -> (entries: []wire.Dir_Entry, err: os.Error) {
    assert(len(dir) > 0, "browse needs a canonicalized directory")

    infos := os.read_all_directory_by_path(dir, allocator) or_return

    out := make([dynamic]wire.Dir_Entry, 0, len(infos), allocator)
    for info in infos {
        if info.name == ".git" {
            continue
        }

        if len(info.name) > 256 {
            // Some filesystems (APFS) allow names up to 255 characters, up to ~1020
            // UTF-8 bytes, past the wire's 256-byte Dir_Entry.name bound. Such an entry
            // is unrepresentable on the wire, so it is skipped rather than aborting.
            continue
        }

        if !utf8.valid_string(info.name) || !utf8.valid_string(info.fullpath) {
            // Filesystem bytes are untrusted: a non-UTF-8 name or path cannot ride a
            // WebSocket TEXT frame (RFC 6455 §5.6), so it is skipped, not emitted.
            continue
        }

        if !daemon_info_is_dir(info, allocator) {
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

    slice.sort_by(out[:], daemon_dir_entry_less)

    return out[:], nil
}

// Whether a directory entry resolves to a directory, following a symlink or an entry
// whose type the platform left undetermined.
daemon_info_is_dir :: proc(info: os.File_Info, allocator: mem.Allocator) -> bool {
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
daemon_dir_entry_less :: proc(a, b: wire.Dir_Entry) -> bool {
    an := a.name
    bn := b.name
    n := min(len(an), len(bn))

    for i in 0 ..< n {
        ca := daemon_ascii_lower(an[i])
        cb := daemon_ascii_lower(bn[i])
        if ca != cb {
            return ca < cb
        }
    }

    return len(an) < len(bn)
}

daemon_ascii_lower :: proc(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' {
        return c + 32
    }

    return c
}
