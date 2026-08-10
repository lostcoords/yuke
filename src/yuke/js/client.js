// yuke:client — typed client script surface over the private native wire bridge.
import { native } from "yuke:client-native";

export class ClientError extends Error {
  constructor(code) {
    super(String(code));
    this.name = "ClientError";
    this.code = String(code);
  }
}

export class RpcError extends Error {
  constructor(code, message) {
    super(String(message));
    this.name = "RpcError";
    this.code = Number(code);
  }
}

function clientError(reason) {
  return reason instanceof ClientError ? reason : new ClientError(reason);
}

function request(method, params) {
  return native.request(method, params).then(
    (text) => {
      const response = JSON.parse(text);
      if (response.error) {
        throw new RpcError(response.error.code, response.error.message);
      }

      return response.result;
    },
    (reason) => {
      throw clientError(reason);
    },
  );
}

export function connect(options) {
  return native.connect(options).catch((reason) => {
    throw clientError(reason);
  });
}

export function disconnect() {
  native.disconnect();
}

export function connectionState() {
  return native.state();
}

export function sessionList(params = {}) {
  return request("session.list", {
    scope: { type: "all" },
    population: { type: "top_level" },
    view: "active_recent",
    ...params,
  });
}
