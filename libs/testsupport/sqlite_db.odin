package testsupport

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

// Database path in a unique per-test temporary directory.
sqlite_db_path :: proc(t: ^testing.T, name: string) -> string {
    dir, dir_err := os.make_directory_temp("", fmt.tprintf("yuke-%s-*", name), context.temp_allocator)
    testing.expect(t, dir_err == nil, "make_directory_temp failed")

    path, join_err := filepath.join({dir, "store.db"}, context.temp_allocator)
    testing.expect(t, join_err == nil, "join failed")

    return path
}

// Removes the database, WAL sidecars, and its unique temporary directory.
sqlite_db_remove :: proc(path: string) {
    os.remove(path)
    os.remove(fmt.tprintf("%s-wal", path))
    os.remove(fmt.tprintf("%s-shm", path))
    os.remove(fmt.tprintf("%s-journal", path))
    os.remove(filepath.dir(path))
}
