package daemon

import "base:runtime"
import "core:mem"
import "core:os"
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
    defer os.file_info_delete(info, allocator)

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

// List one bounded page of immediate subdirectories after `cursor`. The scan retains
// only the smallest page plus one name, regardless of directory size.
browse_entries_page :: proc(
    dir: string,
    cursor: string,
    page_size: int,
    allocator: mem.Allocator,
) -> (
    entries: []wire.Dir_Entry,
    has_more: bool,
    err: os.Error,
) {
    assert(len(dir) > 0, "browse needs a canonicalized directory")
    assert(page_size > 0 && page_size <= wire.LIMITS.max_workspace_browse_page_size, "browse needs a bounded page")

    directory, open_err := os.open(dir, {.Read})
    if open_err != nil {
        return nil, false, open_err
    }
    defer os.close(directory)

    iterator := os.read_directory_iterator_create(directory)
    defer os.read_directory_iterator_destroy(&iterator)

    WINDOW_MAX :: wire.LIMITS.max_workspace_browse_page_size + 1
    names: [WINDOW_MAX]string
    name_count := 0
    window_size := page_size + 1
    heap := runtime.heap_allocator()
    defer {
        for name in names[:name_count] {
            delete(name, heap)
        }
    }

    for info in os.read_directory_iterator(&iterator) {
        if info.name == ".git" {
            continue
        }

        if len(info.name) > 256 {
            continue
        }

        if !utf8.valid_string(info.name) || !utf8.valid_string(info.fullpath) {
            continue
        }

        if cursor != "" && !dir_name_less(cursor, info.name) {
            continue
        }

        insert_at := 0
        for insert_at < name_count && dir_name_less(names[insert_at], info.name) {
            insert_at += 1
        }
        if name_count == window_size && insert_at == name_count {
            continue
        }

        if !file_info_is_dir(info, allocator) {
            continue
        }

        cloned, clone_err := strings.clone(info.name, heap)
        if clone_err != nil {
            return nil, false, clone_err
        }

        if name_count < window_size {
            name_count += 1
        } else {
            delete(names[name_count - 1], heap)
        }
        for index := name_count - 1; index > insert_at; index -= 1 {
            names[index] = names[index - 1]
        }
        names[insert_at] = cloned
    }

    if _, iterator_err := os.read_directory_iterator_error(&iterator); iterator_err != nil {
        return nil, false, iterator_err
    }

    has_more = name_count > page_size
    entry_count := min(name_count, page_size)
    allocated_entries, entries_aerr := make([]wire.Dir_Entry, entry_count, allocator)
    if entries_aerr != nil {
        return nil, false, entries_aerr
    }
    entries = allocated_entries

    for name, index in names[:entry_count] {
        owned_name, name_aerr := strings.clone(name, allocator)
        path, path_aerr := os.join_path({dir, name}, allocator)
        if name_aerr != nil || path_aerr != nil {
            return nil, false, name_aerr if name_aerr != nil else path_aerr
        }

        git_path, git_aerr := strings.concatenate({path, "/.git"}, allocator)
        if git_aerr != nil {
            return nil, false, git_aerr
        }
        entries[index] = {
            name        = owned_name,
            path        = path,
            is_git_repo = os.exists(git_path),
        }
    }

    return entries, has_more, nil
}

// Whether a directory entry resolves to a directory, following a symlink or an entry
// whose type the platform left undetermined.
file_info_is_dir :: proc(info: os.File_Info, allocator: mem.Allocator) -> bool {
    if info.type == .Directory {
        return true
    }

    if info.type == .Symlink || info.type == .Undetermined {
        resolved, err := os.stat(info.fullpath, allocator)
        defer if err == nil {
            os.file_info_delete(resolved, allocator)
        }

        return err == nil && resolved.type == .Directory
    }

    return false
}

// ASCII-folded ordering with a raw-byte tie break, so case variants form a total order.
dir_name_less :: proc(a, b: string) -> bool {
    n := min(len(a), len(b))

    for i in 0 ..< n {
        ca := ascii_lower(a[i])
        cb := ascii_lower(b[i])
        if ca != cb {
            return ca < cb
        }
    }

    if len(a) != len(b) {
        return len(a) < len(b)
    }

    return a < b
}

ascii_lower :: proc(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' {
        return c + 32
    }

    return c
}
