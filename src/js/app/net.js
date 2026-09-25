import * as native from "yuke:internal/native/net";

/** @import { ConnectOptions, Socket } from "yuke:internal/native/net" */

export const net = {
  /** @param {ConnectOptions} options @returns {Promise<Socket>} */
  async connect(options) {
    const id = await native.connect(options);
    return {
      read(options) { return native.read(id, options); },
      write(bytes, options) { return native.write(id, bytes, options); },
      close() { native.close(id); },
    };
  },
};
