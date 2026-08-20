// Generated protocol surface.
export * from "./generated/types.js";
export * from "./generated/methods.js";
export * from "./generated/broadcasts.js";
export * from "./generated/errors.js";
export * from "./generated/limits.js";
// Client.
export { BROADCAST_BACKLOG, Client } from "./client.js";
export { WebSocketTransport, } from "./transport.js";
export { BacklogError, ClosedError, GapError, ProtocolError, RpcError } from "./errors.js";
export { assertBroadcast, assertParams, assertResult, WireValidationError } from "./validate.js";
// Session projection (client-side transcript replica).
export { SessionReplica, ReplicaError, } from "./session.js";
// Daemon discovery.
export { discoverDaemon, DEFAULT_DAEMON_PORT, DEFAULT_DAEMON_HOST, } from "./discovery.js";
// Control-plane HTTP (roster + connect tickets).
export { fetchDeviceRoster, fetchConnectTicket, decodeRosterPin, ROSTER_PIN_BYTES, } from "./roster.js";
// Control-plane account (session token or browser cookie).
export { Account, connect, } from "./account.js";
// Framework-free transcript pump and one-shot prompt.
export { attach } from "./attach.js";
export { run } from "./run.js";
//# sourceMappingURL=index.js.map