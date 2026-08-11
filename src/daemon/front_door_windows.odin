#+build windows
package daemon

import "core:nbio"
import "core:os"
import win32 "core:sys/windows"

// Whether the opened blob handle still refers to the file `os.lstat` validated, closing the
// lstat/open TOCTOU. `os.File_Info.inode` on Windows is the NTFS file index
// (`nFileIndexHigh<<32 | nFileIndexLow`, per `core:os` stat_windows), so rereading that index from
// the handle and comparing is the exact parallel of the posix `st_ino` check. A file-id collision
// across volumes is not disambiguated here, but blobs live under a single content-addressed root.
blob_handle_matches :: proc(file: nbio.Handle, info: os.File_Info) -> bool {
    opened: win32.BY_HANDLE_FILE_INFORMATION
    if !win32.GetFileInformationByHandle(win32.HANDLE(uintptr(file)), &opened) {
        return false
    }

    index := u128(u64(opened.nFileIndexHigh) << 32 + u64(opened.nFileIndexLow))

    return index == info.inode
}
