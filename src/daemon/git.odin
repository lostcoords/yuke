package daemon

import "core:mem"
import "core:os"
import "core:strings"
import wire "src:wire"

// Git status for a workspace root: null when it is not a repo (no `.git`), else the
// branch parsed from `.git/HEAD`. Dirty detection needs the git binary, which this
// step deliberately avoids, so `dirty` is always reported false.
git_info :: proc(root: string, allocator: mem.Allocator) -> Maybe(wire.Git_Info) {
    assert(len(root) > 0, "git info needs a canonical root")

    git_marker := strings.concatenate({root, "/.git"}, allocator)
    if !os.exists(git_marker) {
        return nil
    }

    return wire.Git_Info{branch = git_branch(root, allocator), dirty = false}
}

// Current branch from `.git/HEAD`: the ref name for a symbolic HEAD, or "" for a
// detached, unreadable, or non-UTF-8 HEAD. Clamped to the `Git_Info.branch` bound.
git_branch :: proc(root: string, allocator: mem.Allocator) -> string {
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

    return clamp_utf8_bytes(branch, 256)
}
