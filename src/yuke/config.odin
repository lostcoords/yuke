package main

import daemon "src:daemon"
import "src:paths"

// The bootstrap options `start` needs before the manifest runs: the build version, the default
// port, and the platform data-directory paths. Config and data follow `YUKE_APPNAME` through
// `paths`. Every other operator-facing value comes from `yuked.js`.
boot_options :: proc(version: string, allocator := context.allocator) -> daemon.Options {
    options := daemon.Options {
        daemon_version = version,
        // The manifest supersedes this only when it sets a non-zero port.
        port           = daemon.DEFAULT_PORT,
    }

    // Store and blobs default under the platform data directory; `data_dir` keeps the base itself
    // for the device-identity read. An unresolved base leaves all three empty.
    if base := paths.data_dir(allocator); base != "" {
        options.db_path = paths.db_path_in(base, allocator)
        options.blob_dir = paths.blob_dir_in(base, allocator)
        options.data_dir = base
    }

    return options
}
