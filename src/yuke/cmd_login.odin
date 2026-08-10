/*
yuke login (`yuke login`): device-code enrollment. Generates the device's X25519 static key,
exchanges it for a credential through the control plane's device-code flow, and writes the
identity into `~/.config/yuke`. Implemented in the next slice; this is the dispatch stub.
*/
package main

import "core:fmt"
import "core:os"

// The `login` subcommand. A placeholder until the control-plane enrollment lands.
login_run :: proc() {
    fmt.eprintln("yuke login: not implemented yet")
    os.exit(1)
}
