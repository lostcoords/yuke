import * as native from "yuke:internal/native/net";

/** @import { ConnectOptions, Socket } from "yuke:internal/native/net" */

/** Byte streams over Unix domain sockets. */
export const net = {
  /**
   * Connect to the Unix socket at `options.path`. The host allows at most 64 live connections. The caller closes the socket.
   * @param {ConnectOptions} options @returns {Promise<Socket>}
   */
  async connect(options) {
    const id = await native.connect(options);
    return {
      read(options) { return native.read(id, options); },
      write(bytes, options) { return native.write(id, bytes, options); },
      close() { native.close(id); },
    };
  },
};
