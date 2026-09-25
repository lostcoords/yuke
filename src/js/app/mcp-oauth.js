// yuke:mcp-oauth — OAuth 2.1 sign-in for MCP servers over HTTP: discovery, registration, PKCE with a loopback callback, and refresh.
import * as native from "yuke:oauth-native";
import * as mcpNative from "yuke:mcp-native";
import { fetch } from "yuke:http";

/** @import { CancellationSignal } from "yuke:cancellation-native" */

/** @typedef {{ client_id: string, client_secret?: string }} Client */
/** @typedef {{ access_token: string, refresh_token?: string, expires_at?: number, scope?: string, client: Client, token_endpoint: string, issuer: string, resource: string }} Grant */
/** @typedef {{ clientId?: string, clientSecret?: string, scopes?: string[] }} OAuthConfig */
/** @typedef {{ header(): Promise<string | null>, renew(sent: string | null): Promise<boolean> }} Auth */

// One metadata, registration, or token exchange waits this long.
const EXCHANGE_MS = 30_000;
// The user signs in within this time, or the listener closes.
const CALLBACK_MS = 300_000;
// A token this close to its expiry refreshes first, so a request does not race the expiry.
const EXPIRY_MARGIN_MS = 60_000;
const CLIENT_NAME = "yuke";

/** @param {unknown} value @returns {value is Record<string, unknown>} */
export const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);

// The `application/x-www-form-urlencoded` byte encoding: every byte but alphanumerics and `*-._` is escaped, and a space is `+`.
/** @param {string} text @returns {string} */
function formEncode(text) {
  return encodeURIComponent(text).replace(/[!'()~]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase()).replace(/%20/g, "+");
}

/** @param {Record<string, string | undefined>} fields @returns {string} */
function form(fields) {
  return Object.entries(fields).filter(([, value]) => value !== undefined).map(([key, value]) => formEncode(key) + "=" + formEncode(/** @type {string} */ (value))).join("&");
}

// The parameters of a request target. A repeated key keeps its first value, and a bad escape reads as absent.
/** @param {string} target @returns {Record<string, string>} */
function queryOf(target) {
  /** @type {Record<string, string>} */
  const out = Object.create(null);
  const start = target.indexOf("?");
  if (start < 0) return out;
  for (const pair of target.slice(start + 1).split("&")) {
    const equals = pair.indexOf("=");
    try {
      const key = decodeURIComponent((equals < 0 ? pair : pair.slice(0, equals)).replace(/\+/g, " "));
      if (key !== "" && !(key in out)) out[key] = equals < 0 ? "" : decodeURIComponent(pair.slice(equals + 1).replace(/\+/g, " "));
    } catch { /* A malformed pair names nothing. */ }
  }
  return out;
}

// An issuer or a resource is an absolute URL with no query and no fragment.
/** @param {string} url @returns {boolean} */
function bare(url) {
  return secure(url) && !/[?#]/.test(url);
}

// The lowercase scheme and authority of an absolute URL, and its path.
/** @param {string} url @returns {{ origin: string, path: string }} */
export function split(url) {
  const match = /^(https?:\/\/[^/?#]+)([^?#]*)/i.exec(url);
  return { origin: match?.[1]?.toLowerCase() ?? "", path: match?.[2] ?? "" };
}

// A token or a code crosses the network, so every OAuth URL is https; a loopback host is the one exception.
/** @param {string} url @returns {boolean} */
function secure(url) {
  return /^https:\/\//i.test(url) || /^http:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/i.test(url);
}

// The well-known URLs of RFC 8414 and RFC 9728: the segment goes between the host and the path, then the host alone.
/** @param {string} url @param {string} suffix @returns {string[]} */
function wellKnown(url, suffix) {
  const { origin, path } = split(url);
  const trimmed = path.replace(/\/+$/, "");
  return trimmed ? [origin + "/.well-known/" + suffix + trimmed, origin + "/.well-known/" + suffix] : [origin + "/.well-known/" + suffix];
}

/** @param {string} url @returns {Promise<Record<string, any> | null>} */
async function getJson(url) {
  if (!secure(url)) return null;
  const response = await fetch(url, { headers: { accept: "application/json" }, timeoutMs: EXCHANGE_MS });
  if (!response.ok) {
    response.body.cancel();
    return null;
  }
  const value = await response.json().catch(() => null);
  return record(value) ? value : null;
}

// The parameters of a Bearer challenge in `WWW-Authenticate`.
/** @param {string} header @returns {Record<string, string>} */
function challengeOf(header) {
  /** @type {Record<string, string>} */
  const out = Object.create(null);
  for (const [, key = "", value = ""] of header.matchAll(/([A-Za-z_]+)="([^"]*)"/g)) if (!(key in out)) out[key] = value;
  return out;
}

// Find the authorization server of a protected MCP server. A server with no metadata predates RFC 9728, so its origin serves the defaults of MCP 2025-03-26.
/** @param {string} url @param {string} challenge */
async function discover(url, challenge) {
  const params = challengeOf(challenge);
  let resourceMeta = null;
  for (const candidate of params.resource_metadata ? [params.resource_metadata] : wellKnown(url, "oauth-protected-resource")) {
    resourceMeta = await getJson(candidate);
    if (resourceMeta) break;
  }
  const origin = split(url).origin;
  const servers = resourceMeta?.authorization_servers;
  const issuer = Array.isArray(servers) && typeof servers[0] === "string" ? servers[0] : origin;
  if (!bare(issuer)) throw new Error("the authorization server is not an https URL without a query");
  // RFC 9728 binds the metadata to its resource; a token for it may cover this URL and never another origin or path.
  const resource = typeof resourceMeta?.resource === "string" ? resourceMeta.resource : url.replace(/#.*$/, "");
  const scope_of = split(resource);
  if (!bare(resource) || scope_of.origin !== origin || !(split(url).path + "/").startsWith(scope_of.path.replace(/\/*$/, "/"))) throw new Error("the protected-resource metadata names another resource");
  let meta = null;
  const candidates = [...wellKnown(issuer, "oauth-authorization-server"), ...wellKnown(issuer, "openid-configuration"), issuer.replace(/\/+$/, "") + "/.well-known/openid-configuration"];
  for (const candidate of new Set(candidates)) {
    meta = await getJson(candidate);
    if (meta) break;
  }
  if (!meta) {
    if (resourceMeta) throw new Error("the authorization server publishes no metadata");
    meta = { issuer, authorization_endpoint: origin + "/authorize", token_endpoint: origin + "/token", registration_endpoint: origin + "/register", code_challenge_methods_supported: ["S256"] };
  }
  // RFC 8414 binds the metadata to its issuer, so a copy that names another issuer, or none, is refused.
  if (meta.issuer !== issuer) throw new Error("the authorization server metadata names another issuer");
  if (typeof meta.authorization_endpoint !== "string" || !secure(meta.authorization_endpoint)) throw new Error("the authorization endpoint is missing or not https");
  if (typeof meta.token_endpoint !== "string" || !secure(meta.token_endpoint)) throw new Error("the token endpoint is missing or not https");
  if (!Array.isArray(meta.code_challenge_methods_supported) || !meta.code_challenge_methods_supported.includes("S256")) throw new Error("the authorization server does not state PKCE S256 support");
  const supported = resourceMeta?.scopes_supported;
  const scope = params.scope ?? (Array.isArray(supported) && supported.every((item) => typeof item === "string") ? supported.join(" ") : undefined);
  return { issuer, meta, resource, scope };
}

// Name the client: a configured id first, then dynamic registration (RFC 7591) as a public native client.
/** @param {Record<string, any>} meta @param {string} redirect @param {OAuthConfig} config @returns {Promise<Client>} */
async function register(meta, redirect, config) {
  if (config.clientId) return config.clientSecret ? { client_id: config.clientId, client_secret: config.clientSecret } : { client_id: config.clientId };
  if (typeof meta.registration_endpoint !== "string" || !secure(meta.registration_endpoint)) throw new Error("the server offers no client registration; set oauth.clientId in .mcp.json");
  const response = await fetch(meta.registration_endpoint, {
    method: "POST",
    headers: { "content-type": "application/json", accept: "application/json" },
    // A native client names its type, so a server with OIDC rules accepts the loopback redirect.
    body: JSON.stringify({ client_name: CLIENT_NAME, application_type: "native", redirect_uris: [redirect], grant_types: ["authorization_code", "refresh_token"], response_types: ["code"], token_endpoint_auth_method: "none" }),
    timeoutMs: EXCHANGE_MS,
  });
  const answer = await response.json().catch(() => null);
  if (!response.ok || !record(answer) || typeof answer.client_id !== "string") throw new Error("the client registration failed (HTTP " + response.status + ")");
  return typeof answer.client_secret === "string" ? { client_id: answer.client_id, client_secret: answer.client_secret } : { client_id: answer.client_id };
}

// One token request. A confidential client authenticates with HTTP Basic, as RFC 6749 section 2.3.1 asks.
/** @param {string} endpoint @param {Client} client @param {Record<string, string | undefined>} fields @returns {Promise<Record<string, any>>} */
async function tokenRequest(endpoint, client, fields) {
  /** @type {Record<string, string>} */
  const headers = { "content-type": "application/x-www-form-urlencoded", accept: "application/json" };
  if (client.client_secret) headers.authorization = "Basic " + btoa(formEncode(client.client_id) + ":" + formEncode(client.client_secret));
  const response = await fetch(endpoint, { method: "POST", headers, body: form({ ...fields, client_id: client.client_id }), timeoutMs: EXCHANGE_MS });
  const answer = await response.json().catch(() => null);
  if (!response.ok || !record(answer)) {
    const reason = record(answer) && typeof answer.error === "string" ? answer.error + (typeof answer.error_description === "string" ? ": " + answer.error_description : "") : "HTTP " + response.status;
    throw new Error("the token request failed (" + reason + ")");
  }
  if (typeof answer.access_token !== "string" || answer.access_token === "" || typeof answer.token_type !== "string" || answer.token_type.toLowerCase() !== "bearer") throw new Error("the token answer holds no bearer token");
  return answer;
}

/** @param {Record<string, any>} token @param {Omit<Grant, "access_token" | "refresh_token" | "expires_at" | "scope">} base @param {Grant} [previous] @returns {Grant} */
function grantOf(token, base, previous) {
  /** @type {Grant} */
  const grant = { ...base, access_token: token.access_token };
  // A refresh that answers no new refresh token keeps the old one.
  const refresh = typeof token.refresh_token === "string" ? token.refresh_token : previous?.refresh_token;
  if (refresh) grant.refresh_token = refresh;
  if (Number.isFinite(token.expires_in) && token.expires_in > 0) grant.expires_at = Date.now() + token.expires_in * 1000;
  const scope = typeof token.scope === "string" ? token.scope : previous?.scope;
  if (scope) grant.scope = scope;
  return grant;
}

// The stored grant for a server, or null. A record from another version that lacks a field reads as absent.
/** @param {string} url @returns {Grant | null} */
function stored(url) {
  const text = mcpNative.readRecord("mcp-oauth", url);
  if (text === undefined) return null;
  let grant;
  try { grant = JSON.parse(text); } catch { return null; }
  if (!record(grant) || typeof grant.access_token !== "string" || !record(grant.client) || typeof grant.client.client_id !== "string" || typeof grant.token_endpoint !== "string" || typeof grant.resource !== "string") return null;
  return /** @type {Grant} */ (grant);
}

/** @param {string} url */
export function forget(url) {
  mcpNative.removeRecord("mcp-oauth", url);
}

// The challenge scope is what the current operation needs, so configured scopes join it and never replace it.
/** @param {string[] | undefined} configured @param {string | undefined} challenged @returns {string | undefined} */
function scopeFor(configured, challenged) {
  const scopes = new Set([...(challenged?.split(" ") ?? []), ...(configured ?? [])].filter((scope) => scope !== ""));
  return scopes.size === 0 ? undefined : [...scopes].join(" ");
}

// Sign in to one server: discover, register, authorize in the browser, and store the grant.
/** @param {string} url @param {{ challenge?: string, config?: OAuthConfig, open(url: string): Promise<void> | void, signal?: CancellationSignal }} options @returns {Promise<Grant>} */
export async function signIn(url, { challenge = "", config = {}, open, signal }) {
  const found = await discover(url, challenge);
  const listener = native.listen();
  try {
    const redirect = "http://127.0.0.1:" + listener.port + "/callback";
    const client = await register(found.meta, redirect, config);
    const verifier = native.random(32);
    const state = native.random(16);
    const endpoint = /** @type {string} */ (found.meta.authorization_endpoint);
    const authorize = endpoint + (endpoint.includes("?") ? "&" : "?") + form({
      response_type: "code",
      client_id: client.client_id,
      redirect_uri: redirect,
      code_challenge: native.sha256(verifier),
      code_challenge_method: "S256",
      state,
      resource: found.resource,
      scope: scopeFor(config.scopes, found.scope),
    });
    const callback = native.accept(listener.id, signal ? { timeoutMs: CALLBACK_MS, signal } : { timeoutMs: CALLBACK_MS });
    await open(authorize);
    const answer = queryOf(await callback);
    if (answer.state !== state) throw new Error("the sign-in answer does not match its request");
    if (answer.error) throw new Error("the authorization server refused the sign-in (" + answer.error + (answer.error_description ? ": " + answer.error_description : "") + ")");
    // RFC 9207: an answer that names an issuer must name this one, and a server that promises the parameter must send it.
    if (answer.iss !== undefined ? answer.iss !== found.issuer : found.meta.authorization_response_iss_parameter_supported === true) throw new Error("the sign-in answer names another issuer");
    if (!answer.code) throw new Error("the sign-in answer holds no code");
    const token = await tokenRequest(found.meta.token_endpoint, client, { grant_type: "authorization_code", code: answer.code, redirect_uri: redirect, code_verifier: verifier, resource: found.resource });
    const grant = grantOf(token, { client, token_endpoint: found.meta.token_endpoint, issuer: found.issuer, resource: found.resource });
    mcpNative.writeRecord("mcp-oauth", url, JSON.stringify(grant));
    return grant;
  } finally {
    native.close(listener.id);
  }
}

// Exchange the refresh token. Another process may rotate it first, so a failure takes a newer stored grant before it gives up.
/** @param {string} url @param {Grant} grant @returns {Promise<Grant | null>} */
async function refreshed(url, grant) {
  if (!grant.refresh_token) return null;
  let token;
  try {
    token = await tokenRequest(grant.token_endpoint, grant.client, { grant_type: "refresh_token", refresh_token: grant.refresh_token, resource: grant.resource });
  } catch {
    const current = stored(url);
    return current && current.access_token !== grant.access_token ? current : null;
  }
  const next = grantOf(token, { client: grant.client, token_endpoint: grant.token_endpoint, issuer: grant.issuer, resource: grant.resource }, grant);
  mcpNative.writeRecord("mcp-oauth", url, JSON.stringify(next));
  return next;
}

// The bearer header of one server. It reads the store once, refreshes near the expiry, and renews after a 401.
/** @param {string} url @returns {Auth} */
export function authFor(url) {
  /** @type {Grant | null | undefined} */
  let grant;
  /** @type {Promise<Grant | null> | null} */
  let refreshing = null;
  // Concurrent requests share one refresh, so a rotated refresh token is spent once.
  /** @param {Grant} current */
  const refresh = (current) => {
    refreshing ??= refreshed(url, current).finally(() => { refreshing = null; });
    return refreshing;
  };
  return {
    async header() {
      if (grant === undefined) grant = stored(url);
      if (grant && grant.expires_at !== undefined && grant.expires_at - EXPIRY_MARGIN_MS < Date.now()) grant = await refresh(grant);
      return grant ? "Bearer " + grant.access_token : null;
    },
    async renew(sent) {
      // A sign-in or another process may have stored a newer grant than the one this request sent.
      const latest = stored(url);
      if (latest && "Bearer " + latest.access_token !== sent) {
        grant = latest;
        return true;
      }
      grant = latest ? await refresh(latest) : null;
      return grant !== null;
    },
  };
}
