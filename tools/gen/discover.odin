package gen

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Every regular file directly in `dir` ending in `suffix`, joined into full paths
// and sorted — the numbered-filename order migrations and query files are both
// named to give. Each returned path is caller-owned.
list_files :: proc(
    dir: string,
    suffix: string,
    d: ^Diags,
    allocator := context.allocator,
) -> (
    paths: []string,
    ok: bool,
) {
    assert(d != nil, "list_files needs a diagnostic sink")

    infos, dir_err := os.read_directory_by_path(dir, -1, allocator)

    if dir_err != nil {
        diagf(d, Pos{file = dir}, "cannot read the directory")

        return nil, false
    }

    defer os.file_info_slice_delete(infos, allocator)

    out := make([dynamic]string, 0, len(infos), allocator)

    for info in infos {
        if info.type != .Regular || !strings.has_suffix(info.name, suffix) {
            continue
        }

        joined, join_err := filepath.join({dir, info.name}, allocator)

        if join_err != nil {
            diagf(d, Pos{file = dir}, "cannot build a path for %s", info.name)

            continue
        }

        append(&out, joined)
    }

    slice.sort(out[:])

    return out[:], true
}
