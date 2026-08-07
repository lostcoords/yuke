#+build windows
package term

import "base:runtime"
import "core:sys/windows"

// Fatal-restore state, published while a session is live. The console control handler runs
// on a separate thread with no user pointer, so the snapshot is global; one session may be
// armed per process (asserted on arm).
@(private = "file")
Signal_Restore :: struct {
    armed:      bool,

    // Screen-buffer OUTPUT handle the escape blob is written to.
    out_handle: windows.HANDLE,

    // Saved console input mode, reset by `disable_raw_mode`.
    raw:        Raw_Term,

    // Saved console output mode and code pages, reset by `output_mode_leave`.
    out_mode:   Output_Mode_State,
}

@(private = "file")
g_signal: Signal_Restore

// Console control handler. Windows runs it on a fresh thread and terminates the process
// after it returns (5 s budget for close, 20 s for logoff/shutdown), so a normal Win32
// restore is safe here — unlike the POSIX signal path there is no async-signal constraint.
// Ctrl-C/Break never arrive here in raw mode (ENABLE_PROCESSED_INPUT is off, so they are
// delivered as input), so only the terminating events are handled. Returns FALSE to let the
// default handler carry out the termination.
@(private = "file")
ctrl_handler :: proc "system" (ctrl_type: windows.DWORD) -> windows.BOOL {
    context = runtime.default_context()

    switch ctrl_type {
    case windows.CTRL_CLOSE_EVENT, windows.CTRL_LOGOFF_EVENT, windows.CTRL_SHUTDOWN_EVENT:
        if g_signal.armed {
            written: windows.DWORD
            windows.WriteFile(
                g_signal.out_handle,
                raw_data(SIGNAL_RESTORE_ALL),
                windows.DWORD(len(SIGNAL_RESTORE_ALL)),
                &written,
                nil,
            )
            disable_raw_mode(g_signal.raw)
            output_mode_leave(g_signal.out_mode)
        }
    }

    return windows.FALSE
}

// Install the fatal-signal terminal restore. `out_handle` is the OUTPUT handle the escape
// blob is written to; `raw` and `out_mode` supply the console modes to reset. Only one
// session may be armed per process.
@(private)
signal_restore_arm :: proc(out_handle: Tty_Handle, raw: Raw_Term, out_mode: Output_Mode_State) {
    assert(!g_signal.armed, "signal_restore_arm while already armed")

    g_signal = Signal_Restore {
        armed      = true,
        out_handle = out_handle,
        raw        = raw,
        out_mode   = out_mode,
    }

    windows.SetConsoleCtrlHandler(ctrl_handler, windows.TRUE)
}

// Uninstall the fatal-signal restore: remove the handler, then clear the snapshot.
@(private)
signal_restore_disarm :: proc() {
    if !g_signal.armed {
        return
    }

    windows.SetConsoleCtrlHandler(ctrl_handler, windows.FALSE)
    g_signal = {}
}
