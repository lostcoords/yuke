/** The code of the public module `yuke:net`. Its declaration is `types/net.d.ts`, and the check at the end compares the two. */

import { addAbortStep } from "yuke:internal/events";
import { type NetConnection, netClose, netConnect } from "yuke:internal/native";
import { Connection, ConnectionError, failureOf } from "yuke:internal/net";
import type { ConnectOptions, UnixConnection } from "yuke:net";

export { ConnectionError };

export async function connect(options: ConnectOptions): Promise<UnixConnection> {
  if (options.transport !== "unix") throw new TypeError('the option transport is not "unix"');
  if (!options.path.startsWith("/")) throw new TypeError("the option path is not an absolute path");
  const signal = options.signal;
  signal?.throwIfAborted();
  const { promise, cancel } = netConnect(options.path);
  const remove = signal === undefined ? undefined : addAbortStep(signal, cancel);
  let native: NetConnection;
  try {
    native = await promise;
  } catch (error) {
    throw failureOf(signal, error);
  } finally {
    remove?.();
  }
  // An abort can come after the connect and before this step.
  if (signal?.aborted === true) {
    netClose(native);
    throw signal.reason;
  }
  return new Connection(native, signal);
}

// The check against `types/net.d.ts` keeps this code and the declarations of the authors in step.
const declared = { ConnectionError, connect } satisfies typeof import("yuke:net");
void declared;
