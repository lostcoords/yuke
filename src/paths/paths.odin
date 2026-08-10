package paths

import "core:os"
import "core:path/filepath"
import "core:strings"

// Shared application directory for the TUI, daemon, plugins, and credentials. Both binaries
// resolve the same leaf so the client writes `yuke.js` where the daemon looks for it.
APP_DIR :: "yuke"

// The daemon's private credential file, `auth.json` in the shared application directory.
AUTH_FILE :: "auth.json"

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

// The shared configuration directory, following each platform's convention: `%APPDATA%\yuke`
// on Windows, `$XDG_CONFIG_HOME/yuke` when set, else `~/.config/yuke`. Empty when no base can
// be resolved. This holds `yuke.js`, `yuked.js`, `auth.json`, and `plugins/`.
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

        joined, err := filepath.join({home, ".config", APP_DIR}, allocator)

        return joined if err == nil else ""
    }
}

// The private credential file in the shared application directory. Empty means the platform
// config directory could not be resolved.
auth_path :: proc(allocator := context.allocator) -> string {
    dir := config_dir(allocator)
    if dir == "" {
        return ""
    }

    defer delete(dir, allocator)

    path, err := filepath.join({dir, AUTH_FILE}, allocator)

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

// Join `base` with `APP_DIR`, returning empty on failure so a caller sees "unresolved" rather
// than a half-formed path.
@(private = "file")
join_or_empty :: proc(base: string, allocator := context.allocator) -> string {
    joined, err := filepath.join({base, APP_DIR}, allocator)

    return joined if err == nil else ""
}
