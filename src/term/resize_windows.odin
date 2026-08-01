#+build windows
package term

// Windows has no SIGWINCH. The type exists so cross-platform structs (e.g.
// termdrive.Drive) can name a field; nothing installs or arms a notifier here.
Resize_Notifier :: struct {}
