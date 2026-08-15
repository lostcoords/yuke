package main

import "core:testing"

import daemon "src:daemon"

@(test)
test_boot_options_leaves_config_dir_to_start :: proc(t: ^testing.T) {
    options := boot_options("0.0.0", context.temp_allocator)

    testing.expect_value(t, options.config_dir, "")
    testing.expect_value(t, options.daemon_version, "0.0.0")
    testing.expect_value(t, options.port, daemon.DEFAULT_PORT)
}
