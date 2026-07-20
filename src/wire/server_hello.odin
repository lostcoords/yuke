package wire


// Server `hello` snapshot.

// Daemon identity and clock. Non-owning.
Daemon_Info :: struct {
    // Daemon build/version string. @bounded 32
    version:       string,

    // Daemon wall-clock epoch ms at hello send time.
    server_now_ms: u64,
}

// Write a Daemon_Info object.
daemon_info_emit :: proc(e: ^Emitter, self: Daemon_Info) {
    object_begin(e)
    field_string(e, "version", self.version)
    field_u64(e, "server_now_ms", self.server_now_ms)
    object_end(e)
}

// Coarse daemon snapshot after `client.hello`.
Server_Hello :: struct {
    // Discriminator; must be `"hello"`.
    type:             string,

    // Protocol version the daemon speaks.
    protocol:         u32,

    // Daemon identity and clock.
    daemon:           Daemon_Info,

    // Known workspaces. At most 1024.
    workspaces:       []Workspace,

    // Available profile names. At most 256, each @bounded 64.
    profiles:         []string,

    // Current compact session-index revision for this connection generation.
    session_revision: Session_Revision,

    // Current cron-index revision for this connection generation.
    cron_revision:    Cron_Revision,

    // Catalog content hash. @fixed 64
    catalog_rev:      Catalog_Rev,

    // Catalog load health.
    catalog_health:   Catalog_Health,
}

// Write `type` first, then the remaining hello fields.
server_hello_emit :: proc(e: ^Emitter, self: Server_Hello) {
    object_begin(e)
    field_string(e, "type", self.type)
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
    field_u64(e, "session_revision", u64(self.session_revision))
    field_u64(e, "cron_revision", u64(self.cron_revision))
    field_id(e, "catalog_rev", ([64]u8)(self.catalog_rev))
    key(e, "catalog_health")
    catalog_health_emit(e, self.catalog_health)
    object_end(e)
}

// Verify discriminator, protocol, and annotated field bounds.
server_hello_validate :: proc(self: Server_Hello) -> Validation_Error {
    if self.type != "hello" {
        return .Bad_Frame_Type
    }

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

// Decode a Server_Hello straight from the token stream.
server_hello_from_reader :: proc(d: ^Decoder) -> (out: Server_Hello, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Type,
        Proto,
        Daemon,
        Ws,
        Profiles,
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
        case "type":
            out.type = dec_string(d) or_return
            seen += {.Type}

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

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Type, .Proto, .Daemon, .Ws, .Profiles, .Srev, .Crev, .Catrev, .Health} {
        return {}, .Mismatched_Payload
    }

    return out, .None
}
