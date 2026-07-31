package wire

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
client_from_reader :: proc(d: ^Decoder) -> (out: Client, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Name,
        Version,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "name":
            out.name = dec_string(d) or_return
            seen += {.Name}

        case "version":
            out.version = dec_string(d) or_return
            seen += {.Version}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Name, .Version} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Write the client identity object.
client_emit :: proc(e: ^Emitter, self: Client) {
    object_begin(e)
    field_string(e, "name", self.name)
    field_string(e, "version", self.version)
    object_end(e)
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
    if self.protocol != PROTOCOL_VERSION {
        return .Unsupported_Protocol
    }

    return client_validate(self.client)
}

// Decode straight from the token stream. `protocol` defaults when absent.
initialize_params_from_reader :: proc(d: ^Decoder) -> (out: Initialize_Params, err: Validation_Error) {
    out.protocol = PROTOCOL_VERSION

    Field :: enum {
        Client,
    }

    seen: bit_set[Field]
    dec_object_begin(d) or_return
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "protocol":
            out.protocol = u32(dec_u64(d) or_return)

        case "client":
            out.client = client_from_reader(d) or_return
            seen += {.Client}

        case:
            dec_skip(d) or_return
        }
    }

    if .Client not_in seen {
        return {}, .Mismatched_Payload
    }

    return out, .None
}

// Write `protocol`, then the client object.
initialize_params_emit :: proc(e: ^Emitter, self: Initialize_Params) {
    object_begin(e)
    field_u64(e, "protocol", u64(self.protocol))
    key(e, "client")
    client_emit(e, self.client)
    object_end(e)
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
daemon_info_emit :: proc(e: ^Emitter, self: Daemon_Info) {
    object_begin(e)
    field_string(e, "version", self.version)
    field_u64(e, "server_now_ms", self.server_now_ms)
    object_end(e)
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
initialize_result_emit :: proc(e: ^Emitter, self: Initialize_Result) {
    object_begin(e)
    field_u64(e, "protocol", u64(self.protocol))
    key(e, "daemon")
    daemon_info_emit(e, self.daemon)
    key(e, "workspaces")
    array_begin(e)
    for ws in self.workspaces {
        elem(e)
        workspace_emit(e, ws)
    }

    array_end(e)
    key(e, "profiles")
    array_begin(e)
    for profile in self.profiles {
        elem(e)
        val_string(e, profile)
    }

    array_end(e)
    key(e, "agents")
    array_begin(e)
    for agent in self.agents {
        elem(e)
        val_string(e, agent)
    }

    array_end(e)
    field_u64(e, "session_revision", u64(self.session_revision))
    field_u64(e, "cron_revision", u64(self.cron_revision))
    field_id(e, "catalog_rev", ([64]u8)(self.catalog_rev))
    key(e, "catalog_health")
    catalog_health_emit(e, self.catalog_health)
    key(e, "capabilities")
    array_begin(e)
    for cap in Capability {
        if cap in self.capabilities {
            elem(e)
            val_string(e, capability_wire[cap])
        }
    }

    array_end(e)
    object_end(e)
}

// Verify protocol and annotated field bounds.
initialize_result_validate :: proc(self: Initialize_Result) -> Validation_Error {
    if self.protocol != PROTOCOL_VERSION {
        return .Unsupported_Protocol
    }

    enforce_bounded(32, self.daemon.version) or_return
    enforce_id(([64]u8)(self.catalog_rev)) or_return

    if u64(self.session_revision) > MAX_SESSION_REVISION {
        return .Out_Of_Range
    }

    if u64(self.cron_revision) > MAX_CRON_REVISION {
        return .Out_Of_Range
    }

    if len(self.workspaces) > LIMITS.max_workspaces {
        return .Overflow
    }

    for item in self.workspaces {
        workspace_validate(item) or_return
    }

    if len(self.profiles) > LIMITS.max_profiles {
        return .Overflow
    }

    for profile in self.profiles {
        enforce_bounded(64, profile) or_return
    }

    if len(self.agents) > LIMITS.max_agents {
        return .Overflow
    }

    for agent in self.agents {
        enforce_bounded(64, agent) or_return
    }

    catalog_health_validate(self.catalog_health) or_return

    // Reject any integer carried as a JSON number above the safe range.
    if self.daemon.server_now_ms > MAX_WIRE_INTEGER {
        return .Out_Of_Range
    }

    return .None
}

// --- streaming decoders ---

// Decode a Daemon_Info straight from the token stream.
daemon_info_from_reader :: proc(d: ^Decoder) -> (info: Daemon_Info, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Ver,
        Now,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "version":
            info.version = dec_string(d) or_return
            seen += {.Ver}

        case "server_now_ms":
            info.server_now_ms = dec_u64(d) or_return
            seen += {.Now}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Ver, .Now} {
        return {}, .Mismatched_Payload
    }

    return info, .None
}

// Decode an Initialize_Result straight from the token stream.
initialize_result_from_reader :: proc(d: ^Decoder) -> (out: Initialize_Result, err: Validation_Error) {
    dec_object_begin(d) or_return

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
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "protocol":
            out.protocol = u32(dec_u64(d) or_return)
            seen += {.Proto}

        case "daemon":
            out.daemon = daemon_info_from_reader(d) or_return
            seen += {.Daemon}

        case "workspaces":
            out.workspaces = dec_array(d, workspace_from_reader) or_return
            seen += {.Ws}

        case "profiles":
            out.profiles = dec_array(d, dec_string) or_return
            seen += {.Profiles}

        case "agents":
            out.agents = dec_array(d, dec_string) or_return
            seen += {.Agents}

        case "session_revision":
            out.session_revision = Session_Revision(dec_u64(d) or_return)
            seen += {.Srev}

        case "cron_revision":
            out.cron_revision = Cron_Revision(dec_u64(d) or_return)
            seen += {.Crev}

        case "catalog_rev":
            out.catalog_rev = Catalog_Rev(dec_fixed(d, 64) or_return)
            seen += {.Catrev}

        case "catalog_health":
            out.catalog_health = catalog_health_from_reader(d) or_return
            seen += {.Health}

        case "capabilities":
            dec_array_begin(d) or_return
            for {
                more := dec_elem(d) or_return
                if !more do break
                s := dec_string(d) or_return

                // Tolerant lookup: an unrecognized token is a newer daemon's
                // capability this build doesn't know yet — skip it, don't reject.
                if cap, ok := enum_from_wire(capability_wire, s); ok {
                    out.capabilities += {cap}
                }
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Proto, .Daemon, .Ws, .Profiles, .Agents, .Srev, .Crev, .Catrev, .Health} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}
