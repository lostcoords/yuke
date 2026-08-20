#+build windows
package js

// Windows has no SIGCHLD and no yuke:exec (refused there). The empty type only lets a
// cross-platform struct name the field; a real Windows reaper would use a Job Object.
Child_Reaper :: struct {}
