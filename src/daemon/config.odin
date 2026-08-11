package daemon

import "base:runtime"
import "core:encoding/json"
import "core:log"
import "core:mem"

// Well-known port a launcher binds when the operator configures none, so the web client can probe
// for a local daemon. Applied by the launcher, not `start` (which keeps 0 meaning OS-assigned).
DEFAULT_PORT :: 9853

// The config object `yuked.js` hands to `defineConfig`, camelCase to match the JS surface.
// A partial: every absent member defaults in `start`, so `defineConfig({})` is a valid
// no-op. Superseded field-for-field over the caller's `Options` only when a manifest calls
// `defineConfig`; a script that never calls it leaves `Options` untouched.
Script_Config :: struct {
    // Dotted IPv4 bind address. Empty binds the front door's `127.0.0.1`.
    host:            string `json:"host"`,

    // TCP port for `/ws` and `/blob`. Zero binds an OS-assigned port.
    port:            int `json:"port"`,

    // SQLite database holding the event log. Empty uses a process-lifetime memory store.
    db_path:         string `json:"dbPath"`,

    // Directory holding content-addressed blobs.
    blob_dir:        string `json:"blobDir"`,

    // Bearer token; at least 32 bytes when set. Empty disables authorization.
    auth_token:      string `json:"authToken"`,

    // One of `debug`, `info`, `warn`, `error`. Empty means `info`.
    log_level:       string `json:"logLevel"`,

    // Control-plane base URL the relay exchanges the device credential for link tickets at.
    // Empty means the hosted default (`start` fills it in).
    relay_cloud_url: string `json:"relayCloudUrl"`,

    // Browser origins the front door admits, each a full `scheme://host[:port]`. Empty admits none.
    allowed_origins: []string `json:"allowedOrigins"`,
}

// Decode the JSON captured from `defineConfig`. A malformed value or an unknown member fails
// the start rather than taking half of it — the same strictness the file loader enforced.
config_decode :: proc(text: string, allocator := context.allocator) -> (config: Script_Config, ok: bool) {
    parse_arena: mem.Dynamic_Arena
    mem.dynamic_arena_init(&parse_arena, runtime.heap_allocator(), runtime.heap_allocator())
    defer mem.dynamic_arena_destroy(&parse_arena)

    value, parse_err := json.parse(text, .JSON, true, mem.dynamic_arena_allocator(&parse_arena))
    if parse_err != nil {
        return {}, false
    }

    object, is_object := value.(json.Object)
    if !is_object {
        return {}, false
    }

    for name in object {
        switch name {
        case "host", "port", "dbPath", "blobDir", "authToken", "logLevel", "relayCloudUrl", "allowedOrigins":
        case:
            return {}, false
        }
    }

    if json.unmarshal(transmute([]byte)text, &config, .JSON, allocator) != nil {
        return {}, false
    }

    return config, true
}

// Map the configured level name to the console logger's, defaulting an empty or unrecognized
// one to `info` — a bad level should not stop a daemon, so an unknown one is warned and falls back.
config_log_level :: proc(name: string) -> log.Level {
    switch name {
    case "", "info":
        return .Info

    case "debug":
        return .Debug

    case "warn":
        return .Warning

    case "error":
        return .Error
    }

    log.warnf("daemon: unknown logLevel %q in yuked.js, using info", name)

    return .Info
}
