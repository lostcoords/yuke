package js

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The one path rule every host module follows. A leading `~` expands, a relative path
// resolves against `base`, and an empty `base` rejects relative paths rather than letting
// them mean the process's own working directory.
path_resolve :: proc(base: string, path: string, allocator: mem.Allocator) -> (string, bool) {
    if path == "" {
        return "", false
    }

    resolved := path

    if path == "~" || strings.has_prefix(path, "~/") {
        home, present := os.lookup_env_alloc("HOME", allocator)
        if !present || home == "" {
            return "", false
        }

        joined, join_err := strings.concatenate({home, path[1:]}, allocator)
        if join_err != nil {
            return "", false
        }

        resolved = joined
    } else if !filepath.is_abs(resolved) {
        if base == "" {
            return "", false
        }

        joined, join_err := filepath.join({base, resolved}, allocator)
        if join_err != nil {
            return "", false
        }

        resolved = joined
    }

    cleaned, clean_err := filepath.clean(resolved, allocator)
    if clean_err != nil {
        return "", false
    }

    return cleaned, true
}

// Path is root or beneath it; the separator test stops sibling prefix matches. Used by an
// embedder that contains something of its own, such as the client's module loader.
path_contained :: proc(root: string, path: string) -> bool {
    assert(root != "", "containment needs a root")

    if path == root {
        return true
    }

    if !strings.has_prefix(path, root) {
        return false
    }

    rest := path[len(root):]

    return len(rest) > 0 && rest[0] == filepath.SEPARATOR
}
