package daemon

import "core:hash"
import "core:os"
import wire "src:wire"

// Derived workspace id: FNV-1a-64 over the canonical root's UTF-8 bytes, rendered as 16
// lowercase hex chars, matching the reference daemon so a directory maps to a stable id.
workspace_id :: proc(root: string) -> wire.Workspace_Id {
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
// whole root when it has none (the filesystem root), clamped to `Workspace.title`.
workspace_title :: proc(root: string) -> string {
    assert(len(root) > 0, "workspace title needs a canonical root")

    base := os.base(root)
    title := base
    if title == "" {
        title = root
    }

    return clamp_utf8_bytes(title, 256)
}
