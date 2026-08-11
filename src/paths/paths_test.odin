package paths

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

// `setenv`/`getenv` are not safe to call concurrently, and the runner runs `@(test)` procs in
// parallel, so every test that reads or mutates the environment holds this lock for its whole
// body. The `defer`d restore runs before the unlock (defers are LIFO), so the next test to
// acquire the lock never observes a half-mutated environment.
@(private = "file")
env_lock: sync.Mutex

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
test_config_dir_honors_xdg_on_unix :: proc(t: ^testing.T) {
    sync.mutex_lock(&env_lock)
    defer sync.mutex_unlock(&env_lock)

    when ODIN_OS != .Windows {
        prior, had := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
        defer env_restore("XDG_CONFIG_HOME", prior, had)

        testing.expect(t, os.set_env("XDG_CONFIG_HOME", "/tmp/xdg") == nil, "set xdg")

        dir := config_dir(context.temp_allocator)
        want, _ := filepath.join({"/tmp/xdg", APP_DIR}, context.temp_allocator)

        testing.expect_value(t, dir, want)
    }
}

@(test)
test_config_dir_falls_back_to_home_dot_config :: proc(t: ^testing.T) {
    sync.mutex_lock(&env_lock)
    defer sync.mutex_unlock(&env_lock)

    when ODIN_OS != .Windows {
        xdg_prior, xdg_had := os.lookup_env("XDG_CONFIG_HOME", context.temp_allocator)
        home_prior, home_had := os.lookup_env(HOME_ENV, context.temp_allocator)
        defer env_restore("XDG_CONFIG_HOME", xdg_prior, xdg_had)
        defer env_restore(HOME_ENV, home_prior, home_had)

        os.unset_env("XDG_CONFIG_HOME")
        testing.expect(t, os.set_env(HOME_ENV, "/tmp/home") == nil, "set home")

        dir := config_dir(context.temp_allocator)
        want, _ := filepath.join({"/tmp/home", ".config", APP_DIR}, context.temp_allocator)

        testing.expect_value(t, dir, want)
    }
}

@(test)
test_config_dir_names_the_app_directory :: proc(t: ^testing.T) {
    sync.mutex_lock(&env_lock)
    defer sync.mutex_unlock(&env_lock)

    testing.expect_value(t, APP_DIR, "yuke")

    dir := config_dir(context.temp_allocator)

    // Whatever base a platform resolves, the leaf is always the application directory; an
    // unresolved base (no home, no XDG) is the one case with nothing to name.
    if dir != "" {
        testing.expect(t, strings.has_suffix(dir, APP_DIR), "config dir ends in the app directory")
    }
}

@(test)
test_data_dir_honors_xdg_on_unix :: proc(t: ^testing.T) {
    sync.mutex_lock(&env_lock)
    defer sync.mutex_unlock(&env_lock)

    when ODIN_OS != .Windows {
        prior, had := os.lookup_env("XDG_DATA_HOME", context.temp_allocator)
        defer env_restore("XDG_DATA_HOME", prior, had)

        testing.expect(t, os.set_env("XDG_DATA_HOME", "/tmp/xdgdata") == nil, "set xdg data")

        dir := data_dir(context.temp_allocator)
        want, _ := filepath.join({"/tmp/xdgdata", APP_DIR}, context.temp_allocator)

        testing.expect_value(t, dir, want)
    }
}

@(test)
test_data_dir_falls_back_to_home_local_share :: proc(t: ^testing.T) {
    sync.mutex_lock(&env_lock)
    defer sync.mutex_unlock(&env_lock)

    when ODIN_OS != .Windows {
        xdg_prior, xdg_had := os.lookup_env("XDG_DATA_HOME", context.temp_allocator)
        home_prior, home_had := os.lookup_env(HOME_ENV, context.temp_allocator)
        defer env_restore("XDG_DATA_HOME", xdg_prior, xdg_had)
        defer env_restore(HOME_ENV, home_prior, home_had)

        os.unset_env("XDG_DATA_HOME")
        testing.expect(t, os.set_env(HOME_ENV, "/tmp/home") == nil, "set home")

        dir := data_dir(context.temp_allocator)
        want, _ := filepath.join({"/tmp/home", ".local", "share", APP_DIR}, context.temp_allocator)

        testing.expect_value(t, dir, want)
    }
}

@(test)
test_db_and_blob_paths_derive_from_the_data_directory :: proc(t: ^testing.T) {
    testing.expect_value(t, DB_FILE, "yuked.db")
    testing.expect_value(t, BLOB_SUBDIR, "blobs")

    want_db, _ := filepath.join({"/data/yuke", DB_FILE}, context.temp_allocator)
    want_blobs, _ := filepath.join({"/data/yuke", BLOB_SUBDIR}, context.temp_allocator)

    testing.expect_value(t, db_path_in("/data/yuke", context.temp_allocator), want_db)
    testing.expect_value(t, blob_dir_in("/data/yuke", context.temp_allocator), want_blobs)
}
