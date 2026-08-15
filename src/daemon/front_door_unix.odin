#+build !windows
package daemon

import "core:nbio"
import "core:os"
import "core:sys/posix"

// Whether the opened blob handle still refers to the file `os.lstat` validated, comparing the kernel
// inode. A mismatch means the path was swapped between lstat and open, so the handle is rejected.
blob_handle_matches :: proc(file: nbio.Handle, info: os.File_Info) -> bool {
    opened: posix.stat_t
    if posix.fstat(posix.FD(i32(file)), &opened) != .OK {
        return false
    }

    return u128(u64(opened.st_ino)) == info.inode
}
