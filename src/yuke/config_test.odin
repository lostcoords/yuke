package main

import "core:os"
import "core:testing"

// Restore an environment variable to a captured prior state: set it back when it was present,
// unset it when it was not. Paired with a capture at the top of each test so path resolution
// tests never leak a mutated environment into one another.
@(private = "file")
env_restore :: proc(key, prior: string, had: bool) {
    if had {
        os.set_env(key, prior)
    } else {
        os.unset_env(key)
    }
}

@(test)
test_script_root_prefers_the_override :: proc(t: ^testing.T) {
    prior, had := os.lookup_env(ROOT_ENV, context.temp_allocator)
    defer env_restore(ROOT_ENV, prior, had)

    testing.expect(t, os.set_env(ROOT_ENV, "/tmp/custom/yuke") == nil, "set override")

    root := script_root(context.temp_allocator)

    testing.expect_value(t, root, "/tmp/custom/yuke")
}
