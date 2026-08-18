package wire
import "libs:json"

import "core:strings"

// Connection-level client identity.
Client :: struct {
    // @bounded 64
    // Client connection name (e.g. `"yuke-tui"`).
    name:    string,

    // @bounded 32
    // Client build/version string.
    version: string,
}

// Verify annotated field bounds.
client_validate :: proc(self: Client) -> Validation_Error {
    enforce_bounded(64, self.name) or_return

    return enforce_bounded(32, self.version)
}

// Decode the client identity object straight from the token stream.
client_from_reader :: proc(d: ^json.Decoder) -> (out: Client, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Version,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            out.name = json.dec_string(d) or_return
            seen += {.Name}

        case "version":
            out.version = json.dec_string(d) or_return
            seen += {.Version}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Version} do return {}, .Mismatched_Payload

    return out, .None
}

// Write the client identity object.
client_emit :: proc(e: ^json.Emitter, self: Client) {
    json.object_begin(e)
    json.field_string(e, "name", self.name)
    json.field_string(e, "version", self.version)
    json.object_end(e)
}

// Deep-copy into `allocator`.
client_clone :: proc(self: Client, allocator := context.allocator) -> Client {
    return {name = strings.clone(self.name, allocator), version = strings.clone(self.version, allocator)}
}

// Params of the `initialize` request. Non-owning.
Initialize_Params :: struct {
    // @default PROTOCOL_VERSION
    // @const PROTOCOL_VERSION
    // Protocol version this client speaks. Must equal `PROTOCOL_VERSION`.
    protocol: u32,

    // Connection-level client identity.
    client:   Client,
}

// Build initialize params at the current protocol version.
initialize_params_build :: proc(client: Client) -> Initialize_Params {
    return Initialize_Params{protocol = PROTOCOL_VERSION, client = client}
}

// Verify protocol and annotated field bounds.
initialize_params_validate :: proc(self: Initialize_Params) -> Validation_Error {
    if self.protocol != PROTOCOL_VERSION do return .Unsupported_Protocol

    return client_validate(self.client)
}

// Decode straight from the token stream. `protocol` defaults when absent.
initialize_params_from_reader :: proc(d: ^json.Decoder) -> (out: Initialize_Params, err: json.Decode_Error) {
    out.protocol = PROTOCOL_VERSION

    Field :: enum {
        Client,
    }

    seen: bit_set[Field]
    json.dec_object_begin(d) or_return
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "protocol":
            out.protocol = u32(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)

        case "client":
            out.client = client_from_reader(d) or_return
            seen += {.Client}

        case:
            json.dec_skip(d) or_return
        }
    }

    if .Client not_in seen do return {}, .Mismatched_Payload

    return out, .None
}

// Write `protocol`, then the client object.
initialize_params_emit :: proc(e: ^json.Emitter, self: Initialize_Params) {
    json.object_begin(e)
    json.field_u64(e, "protocol", u64(self.protocol))
    json.key(e, "client")
    client_emit(e, self.client)
    json.object_end(e)
}

// Daemon identity and clock. Non-owning.
Daemon_Info :: struct {
    // @bounded 32
    // Daemon build/version string.
    version:       string,

    // Daemon wall-clock epoch ms at initialize time.
    server_now_ms: u64,
}

// Write a Daemon_Info object.
daemon_info_emit :: proc(e: ^json.Emitter, self: Daemon_Info) {
    json.object_begin(e)
    json.field_string(e, "version", self.version)
    json.field_u64(e, "server_now_ms", self.server_now_ms)
    json.object_end(e)
}

// Optional daemon surface a client may probe for. This is the ONE enum decoded
// tolerantly: an unknown capability string is IGNORED, never a Validation_Error.
// Tolerant decode is the whole point — a newer daemon advertises a token an older
// client does not know, and the client must skip it, not reject the frame. Every
// other enum in this package hard-rejects an unknown value; this one must not.
Capability :: enum {
    // Client→daemon blob upload (`PUT /blob/<hash>`).
    Blob_Upload,
}

@(rodata)
capability_wire := [Capability]string {
    .Blob_Upload = "blob_upload",
}

// Result of the `initialize` request: the coarse daemon snapshot.
Initialize_Result :: struct {
    // @const PROTOCOL_VERSION
    // Protocol version the daemon speaks.
    protocol:         u32,

    // Daemon identity and clock.
    daemon:           Daemon_Info,

    // @bounded LIMITS.max_workspaces
    // Known workspaces.
    workspaces:       []Workspace,

    // @bounded LIMITS.max_profiles
    // Available profile names; each element @bounded 64.
    profiles:         []string,

    // @bounded LIMITS.max_agents
    // Available agent names; each element @bounded 64.
    agents:           []string,

    // Current compact session-index revision for this connection generation.
    session_revision: Session_Revision,

    // Current cron-index revision for this connection generation.
    cron_revision:    Cron_Revision,

    // @fixed 64
    // Catalog content hash.
    catalog_rev:      Catalog_Rev,

    // Catalog load health.
    catalog_health:   Catalog_Health,

    // Optional daemon surfaces this build/config advertises; see `Capability`.
    capabilities:     bit_set[Capability],
}

// Write the initialize result.
initialize_result_emit :: proc(e: ^json.Emitter, self: Initialize_Result) {
    json.object_begin(e)
    json.field_u64(e, "protocol", u64(self.protocol))
    json.key(e, "daemon")
    daemon_info_emit(e, self.daemon)
    json.key(e, "workspaces")
    json.array_begin(e)
    for ws in self.workspaces {
        json.elem(e)
        workspace_emit(e, ws)
    }

    json.array_end(e)
    json.key(e, "profiles")
    json.array_begin(e)
    for profile in self.profiles {
        json.elem(e)
        json.val_string(e, profile)
    }

    json.array_end(e)
    json.key(e, "agents")
    json.array_begin(e)
    for agent in self.agents {
        json.elem(e)
        json.val_string(e, agent)
    }

    json.array_end(e)
    json.field_u64(e, "session_revision", u64(self.session_revision))
    json.field_u64(e, "cron_revision", u64(self.cron_revision))
    json.field_id(e, "catalog_rev", ([64]u8)(self.catalog_rev))
    json.key(e, "catalog_health")
    catalog_health_emit(e, self.catalog_health)
    json.key(e, "capabilities")
    json.array_begin(e)
    for cap in Capability {
        if cap in self.capabilities {
            json.elem(e)
            json.val_string(e, capability_wire[cap])
        }
    }

    json.array_end(e)
    json.object_end(e)
}

// Verify protocol and annotated field bounds.
initialize_result_validate :: proc(self: Initialize_Result) -> Validation_Error {
    if self.protocol != PROTOCOL_VERSION do return .Unsupported_Protocol

    enforce_bounded(32, self.daemon.version) or_return
    enforce_id(([64]u8)(self.catalog_rev)) or_return

    if u64(self.session_revision) > MAX_SESSION_REVISION do return .Out_Of_Range

    if u64(self.cron_revision) > MAX_CRON_REVISION do return .Out_Of_Range

    if len(self.workspaces) > LIMITS.max_workspaces do return .Overflow

    for item in self.workspaces {
        workspace_validate(item) or_return
    }

    if len(self.profiles) > LIMITS.max_profiles do return .Overflow

    for profile in self.profiles {
        enforce_bounded(64, profile) or_return
    }

    if len(self.agents) > LIMITS.max_agents do return .Overflow

    for agent in self.agents {
        enforce_bounded(64, agent) or_return
    }

    catalog_health_validate(self.catalog_health) or_return

    // Reject any integer carried as a JSON number above the safe range.
    if self.daemon.server_now_ms > MAX_WIRE_INTEGER do return .Out_Of_Range

    return .None
}

// Decode a Daemon_Info straight from the token stream.
daemon_info_from_reader :: proc(d: ^json.Decoder) -> (info: Daemon_Info, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Ver,
        Now,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "version":
            info.version = json.dec_string(d) or_return
            seen += {.Ver}

        case "server_now_ms":
            info.server_now_ms = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Now}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Ver, .Now} do return {}, .Mismatched_Payload

    return info, .None
}

// Decode an Initialize_Result straight from the token stream.
initialize_result_from_reader :: proc(d: ^json.Decoder) -> (out: Initialize_Result, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Proto,
        Daemon,
        Ws,
        Profiles,
        Agents,
        Srev,
        Crev,
        Catrev,
        Health,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "protocol":
            out.protocol = u32(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Proto}

        case "daemon":
            out.daemon = daemon_info_from_reader(d) or_return
            seen += {.Daemon}

        case "workspaces":
            out.workspaces = json.dec_array(d, workspace_from_reader) or_return
            seen += {.Ws}

        case "profiles":
            out.profiles = json.dec_array(d, json.dec_string) or_return
            seen += {.Profiles}

        case "agents":
            out.agents = json.dec_array(d, json.dec_string) or_return
            seen += {.Agents}

        case "session_revision":
            out.session_revision = Session_Revision(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Srev}

        case "cron_revision":
            out.cron_revision = Cron_Revision(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Crev}

        case "catalog_rev":
            out.catalog_rev = Catalog_Rev(json.dec_fixed(d, 64) or_return)
            seen += {.Catrev}

        case "catalog_health":
            out.catalog_health = catalog_health_from_reader(d) or_return
            seen += {.Health}

        case "capabilities":
            json.dec_array_begin(d) or_return
            for {
                more := json.dec_elem(d) or_return
                if !more do break
                s := json.dec_string(d) or_return

                // Tolerant lookup: an unrecognized token is a newer daemon's
                // capability this build doesn't know yet — skip it, don't reject.
                if cap, ok := json.enum_from_wire(capability_wire, s); ok do out.capabilities += {cap}
            }

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Proto, .Daemon, .Ws, .Profiles, .Agents, .Srev, .Crev, .Catrev, .Health} do return {}, .Mismatched_Payload

    return out, .None
}
