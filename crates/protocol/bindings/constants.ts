// Generated from the protocol constants by the bindings test of `yuke-protocol`. Do not edit.

/** The protocol version of this server. */
export const PROTOCOL_VERSION = 1;

/** The `code` of a failed request: a code of JSON-RPC, or a code of yuke. */
export const ErrorCode = {
  /** The server cannot read the message as JSON. */
  PARSE_ERROR: -32700,
  /** The JSON is no valid message object: no object, or a request without a valid `jsonrpc`, `id`, or `method`. */
  INVALID_REQUEST: -32600,
  /** The server has no such method. */
  METHOD_NOT_FOUND: -32601,
  /** The params do not fit the method. */
  INVALID_PARAMS: -32602,
  /** The server failed. */
  INTERNAL_ERROR: -32603,
  /** The server has no session with this id. */
  SESSION_NOT_FOUND: -32002,
  /** Another writer holds the session. */
  SESSION_OWNED: -32003,
  /** The session runs no background job with this id: the id is unknown, or the job has ended. */
  JOB_NOT_FOUND: -32004,
  /** The session has no open question with this id: the id is unknown, or the question has ended. */
  INTERACTION_NOT_FOUND: -32005,
  /** The server has no login in progress with this id: the id is unknown, or the login has ended. */
  LOGIN_NOT_FOUND: -32006,
  /** The session has no blob with this digest. */
  BLOB_NOT_FOUND: -32007,
  /** The session is open, so the server cannot remove it. Close it first. */
  SESSION_OPEN: -32008,
  /** A turn runs or input waits, so the request cannot run now. Send it again after the turn ends. */
  TURN_ACTIVE: -32009,
  /** Another call opens or closes the session, or a reload runs. Send the request again after it ends. */
  TRY_AGAIN: -32010,
  /** The server shuts down, so it opens no session. */
  STOPPING: -32011,
  /** The connection sent no `initialize` yet. */
  NOT_INITIALIZED: -32012,
} as const;
