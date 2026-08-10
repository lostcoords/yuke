package daemon

import "core:encoding/json"
import "core:log"

// The config object `yuked.js` hands to `defineConfig`, camelCase to match the JS surface.
// A partial: every absent member defaults in `start`, so `defineConfig({})` is a valid
// no-op. Superseded field-for-field over the caller's `Options` only when a manifest calls
// `defineConfig`; a script that never calls it leaves `Options` untouched.
Script_Config :: struct {
    // Dotted IPv4 bind address. Empty binds the front door's `127.0.0.1`.
    host:       string `json:"host"`,

    // TCP port for `/ws` and `/blob`. Zero binds an OS-assigned port.
    port:       int `json:"port"`,

    // SQLite database holding the event log. Empty disables the store, and with it every
    // durable broadcast.
    db_path:    string `json:"dbPath"`,

    // Directory holding content-addressed blobs.
    blob_dir:   string `json:"blobDir"`,

    // Bearer token; at least 32 bytes when set. Empty disables authorization.
    auth_token: string `json:"authToken"`,

    // One of `debug`, `info`, `warn`, `error`. Empty means `info`.
    log_level:  string `json:"logLevel"`,
}

// Decode the JSON captured from `defineConfig`. A malformed value or an unknown member fails
// the start rather than taking half of it — the same strictness the file loader enforced.
config_decode :: proc(text: string, allocator := context.allocator) -> (config: Script_Config, ok: bool) {
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
