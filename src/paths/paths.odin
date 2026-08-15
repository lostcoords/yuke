package paths

import "core:os"
import "core:path/filepath"
import "core:strings"

// Default directory leaf under the XDG / Windows roots. `YUKE_APPNAME` replaces it when set.
APP_DIR :: "yuke"

// Process-wide profile name, like Neovim's `NVIM_APPNAME`. Remaps config and data together.
APP_NAME_ENV :: "YUKE_APPNAME"

// The daemon's SQLite event log, `yuked.db` in the data directory.
DB_FILE :: "yuked.db"

// The content-addressed blob store, the `blobs` subdirectory of the data directory.
BLOB_SUBDIR :: "blobs"

// Home-directory environment variable: `USERPROFILE` on Windows, `HOME` elsewhere. Windows
// has no `HOME`, so resolving against it would leave a binary unable to find its own config.
HOME_ENV :: "USERPROFILE" when ODIN_OS == .Windows else "HOME"

// The user's home directory, or empty when the platform's home variable is unset. Callers
// treat empty as "no home-based path can be resolved" rather than substituting a guess.
home_dir :: proc(allocator := context.allocator) -> string {
    home, found := os.lookup_env(HOME_ENV, allocator)
    if !found {
        return ""
    }

    return home
}

// A single directory name: no slashes, not `.` or `..`. Empty is not a profile.
app_name_valid :: proc(name: string) -> bool {
    if name == "" || name == "." || name == ".." {
        return false
    }

    for r in name {
        if r == '/' || r == '\\' || r == 0 {
            return false
        }
    }

    return true
}

// Reason `YUKE_APPNAME` cannot be used, or empty when the default or a valid name applies.
app_name_error :: proc() -> string {
    value, set := os.lookup_env(APP_NAME_ENV, context.temp_allocator)
    if !set || value == "" {
        return ""
    }

    if !app_name_valid(value) {
        return "YUKE_APPNAME must be a single directory name"
    }

    return ""
}

// Directory leaf under the platform roots. Unset or empty `YUKE_APPNAME` is `APP_DIR`.
// `ok` is false when the env is set to an invalid name; `owned` is true when `name` was cloned.
app_name :: proc(allocator := context.allocator) -> (name: string, owned: bool, ok: bool) {
    value, set := os.lookup_env(APP_NAME_ENV, allocator)
    if !set || value == "" {
        if set {
            delete(value, allocator)
        }

        return APP_DIR, false, true
    }

    if !app_name_valid(value) {
        delete(value, allocator)

        return "", false, false
    }

    return value, true, true
}

// The shared configuration directory: `%APPDATA%\<leaf>` on Windows, `$XDG_CONFIG_HOME/<leaf>`
// when set, else `~/.config/<leaf>`. The leaf is `yuke` or `$YUKE_APPNAME`. Empty when no base
// can be resolved or the profile name is invalid. Holds `yuke.js`, `yuked.js`, and plugins.
config_dir :: proc(allocator := context.allocator) -> string {
    when ODIN_OS == .Windows {
        base, found := os.lookup_env("APPDATA", allocator)
        if !found || base == "" {
            return ""
        }

        defer delete(base, allocator)

        return join_or_empty(base, allocator)
    } else {
        if xdg, set := os.lookup_env("XDG_CONFIG_HOME", allocator); set {
            defer delete(xdg, allocator)

            if xdg != "" {
                return join_or_empty(xdg, allocator)
            }
        }

        home := home_dir(allocator)
        if home == "" {
            return ""
        }

        defer delete(home, allocator)

        return join_under(home, {".config"}, allocator)
    }
}

// The platform data directory: `%LOCALAPPDATA%\<leaf>` on Windows, `$XDG_DATA_HOME/<leaf>`
// when set, else `~/.local/share/<leaf>`. Empty when no base can be resolved or the profile
// name is invalid. Holds the event-log database, blob store, and device identity.
data_dir :: proc(allocator := context.allocator) -> string {
    when ODIN_OS == .Windows {
        base, found := os.lookup_env("LOCALAPPDATA", allocator)
        if !found || base == "" {
            return ""
        }

        defer delete(base, allocator)

        return join_or_empty(base, allocator)
    } else {
        if xdg, set := os.lookup_env("XDG_DATA_HOME", allocator); set {
            defer delete(xdg, allocator)

            if xdg != "" {
                return join_or_empty(xdg, allocator)
            }
        }

        home := home_dir(allocator)
        if home == "" {
            return ""
        }

        defer delete(home, allocator)

        return join_under(home, {".local", "share"}, allocator)
    }
}

// The event-log database path inside `base`, the data directory. Empty only on a join failure.
db_path_in :: proc(base: string, allocator := context.allocator) -> string {
    assert(base != "", "a database path needs a data directory")
    path, err := filepath.join({base, DB_FILE}, allocator)

    return path if err == nil else ""
}

// The blob store directory inside `base`, the data directory. Empty only on a join failure.
blob_dir_in :: proc(base: string, allocator := context.allocator) -> string {
    assert(base != "", "a blob directory needs a data directory")
    path, err := filepath.join({base, BLOB_SUBDIR}, allocator)

    return path if err == nil else ""
}

// Expand a leading `~` against the home directory. Left unchanged when it does not start with
// one or there is no home to expand against, so a caller never reports a half-substituted path.
expand_home :: proc(path: string, allocator := context.allocator) -> string {
    if path == "" || path[0] != '~' {
        return path
    }

    if len(path) > 1 && path[1] != filepath.SEPARATOR {
        return path
    }

    home := home_dir(allocator)
    if home == "" {
        return path
    }

    defer delete(home, allocator)

    rest := strings.trim_left_proc(path[1:], proc(r: rune) -> bool {return r == filepath.SEPARATOR})

    if rest == "" {
        return strings.clone(home, allocator)
    }

    joined, join_err := filepath.join({home, rest}, allocator)
    if join_err != nil {
        return path
    }

    return joined
}

// Join `base` with the profile leaf. Empty on a bad `YUKE_APPNAME` or a join failure.
@(private = "file")
join_or_empty :: proc(base: string, allocator := context.allocator) -> string {
    return join_under(base, {}, allocator)
}

// Join `base`, optional middle segments, and the profile leaf.
@(private = "file")
join_under :: proc(base: string, mid: []string, allocator := context.allocator) -> string {
    assert(len(mid) <= 2, "profile join has at most two middle segments")

    name, owned, ok := app_name(allocator)
    if !ok {
        return ""
    }

    defer if owned {
        delete(name, allocator)
    }

    parts: [4]string
    parts[0] = base
    for p, i in mid {
        parts[1 + i] = p
    }
    parts[1 + len(mid)] = name

    joined, err := filepath.join(parts[:2 + len(mid)], allocator)

    return joined if err == nil else ""
}
