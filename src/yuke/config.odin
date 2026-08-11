package main

import "core:os"

import daemon "src:daemon"
import "src:paths"

// Environment override for the script root — the directory holding `yuked.js`. Lets a second
// daemon run against its own config without disturbing the first; unset uses the shared config
// directory.
ROOT_ENV :: "YUKED_ROOT"

// The script root: `YUKED_ROOT` when set, else the shared config directory when it exists on
// disk. Empty leaves the script tier off — `js.init` rejects a root that is not a directory, so
// an absent config directory reads as "no manifest", not a start failure. Caller owns the result.
script_root :: proc(allocator := context.allocator) -> string {
    if override, set := os.lookup_env(ROOT_ENV, allocator); set {
        expanded := paths.expand_home(override, allocator)

        // `expand_home` returns a fresh string only when it substituted a leading `~`; the
        // original `os.lookup_env` clone is orphaned then, so release it.
        if raw_data(expanded) != raw_data(override) {
            delete(override, allocator)
        }

        return expanded
    }

    dir := paths.config_dir(allocator)
    if dir == "" {
        return ""
    }

    if !os.is_dir(dir) {
        delete(dir, allocator)

        return ""
    }

    return dir
}

// The bootstrap options `start` needs before the manifest runs: the build version, the script
// root, the private credential path, the default port, and the platform data-directory paths.
// Every other operator-facing value (host, dataDir, auth_token, log_level) comes from `yuked.js`'s
// `defineConfig`; the port defaults here and the manifest supersedes it only with a non-zero value.
boot_options :: proc(version: string, allocator := context.allocator) -> daemon.Options {
    options := daemon.Options {
        daemon_version = version,
        js_root        = script_root(allocator),
        auth_path      = paths.auth_path(allocator),
        // The manifest supersedes this only when it sets a non-zero port.
        port           = daemon.DEFAULT_PORT,
    }

    // Store and blobs default under the platform data directory; `dataDir` relocates the base.
    // An unresolved base leaves both empty: memory store, `/blob` disabled.
    if base := paths.data_dir(allocator); base != "" {
        defer delete(base, allocator)

        options.db_path = paths.db_path_in(base, allocator)
        options.blob_dir = paths.blob_dir_in(base, allocator)
    }

    return options
}
