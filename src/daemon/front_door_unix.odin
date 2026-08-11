#+build !windows
package daemon

import "core:nbio"
import "core:os"
import "core:sys/posix"

// Whether the opened blob handle still refers to the file `os.lstat` validated, comparing the
// kernel inode — the only identity `os.File_Info` exposes. A mismatch means the content-addressed
// path was swapped between the lstat and the open, so the handle is rejected.
blob_handle_matches :: proc(file: nbio.Handle, info: os.File_Info) -> bool {
    opened: posix.stat_t
    if posix.fstat(posix.FD(i32(file)), &opened) != .OK {
        return false
    }

    return u128(u64(opened.st_ino)) == info.inode
}
