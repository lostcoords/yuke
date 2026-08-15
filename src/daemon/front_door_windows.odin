#+build windows
package daemon

import "core:nbio"
import "core:os"
import win32 "core:sys/windows"

// Whether the opened blob handle still refers to the file `os.lstat` validated, closing the TOCTOU.
// `inode` here is the NTFS file index, so rereading it from the handle parallels the posix check.
blob_handle_matches :: proc(file: nbio.Handle, info: os.File_Info) -> bool {
    opened: win32.BY_HANDLE_FILE_INFORMATION
    if !win32.GetFileInformationByHandle(win32.HANDLE(uintptr(file)), &opened) {
        return false
    }

    index := u128(u64(opened.nFileIndexHigh) << 32 + u64(opened.nFileIndexLow))

    return index == info.inode
}
