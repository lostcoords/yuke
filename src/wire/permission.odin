package wire

import "core:strings"

// Kinds of options the daemon may propose on a permission prompt.
Permission_Option_Kind :: enum {
    // Allow once for this call only.
    Allow_Once,

    // Allow for the rest of the session.
    Allow_Session,

    // Persist as a workspace rule and allow.
    Allow_Always,

    // Reject this call only.
    Reject_Once,
}

// Permission_Option_Kind <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
permission_option_kind_wire := [Permission_Option_Kind]string {
    .Allow_Once    = "allow_once",
    .Allow_Session = "allow_session",
    .Allow_Always  = "allow_always",
    .Reject_Once   = "reject_once",
}

// Wire string for a permission option kind.
permission_option_kind_to_wire :: proc(k: Permission_Option_Kind) -> string {
    return permission_option_kind_wire[k]
}

// Permission option kind for a wire string; ok is false for an unknown kind.
permission_option_kind_from_wire :: proc(s: string) -> (Permission_Option_Kind, bool) {
    return enum_from_wire(permission_option_kind_wire, s)
}

// Who or what denied a tool call.
Denied_By :: enum {
    // A user selected a reject option.
    User,

    // Daemon policy rejected the call without prompting.
    Policy,
}

// Denied_By <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
denied_by_wire := [Denied_By]string {
    .User   = "user",
    .Policy = "policy",
}

// Wire string for a denied-by value.
denied_by_to_wire :: proc(d: Denied_By) -> string {
    return denied_by_wire[d]
}

// Denied-by value for a wire string; ok is false for an unknown value.
denied_by_from_wire :: proc(s: string) -> (Denied_By, bool) {
    return enum_from_wire(denied_by_wire, s)
}

// One option the daemon proposes for a permission request.
Permission_Option :: struct {
    // Stable option key clients echo back.
    id:      string,

    // Pre-computed classification of this option.
    kind:    Permission_Option_Kind,

    // Human-readable label.
    label:   string,

    // Rule shapes produced when chosen (for `allow_always`). At most 32, each @bounded 512.
    creates: Maybe([]string),
}

// Verify annotated field bounds.
permission_option_validate :: proc(self: Permission_Option) -> Validation_Error {
    enforce_bounded(32, self.id) or_return
    enforce_bounded(256, self.label) or_return

    if creates, ok := self.creates.?; ok {
        if len(creates) > LIMITS.max_permission_creates {
            return .Overflow
        }

        for pattern in creates {
            enforce_bounded(512, pattern) or_return
        }
    }

    return .None
}

// Deep-copy into `allocator`.
permission_option_clone :: proc(self: Permission_Option, allocator := context.allocator) -> Permission_Option {
    creates: Maybe([]string)

    if list, ok := self.creates.?; ok {
        out := make([]string, len(list), allocator)
        for i in 0 ..< len(out) {
            out[i] = strings.clone(list[i], allocator)
        }

        creates = out
    }

    return Permission_Option {
        id = strings.clone(self.id, allocator),
        kind = self.kind,
        label = strings.clone(self.label, allocator),
        creates = creates,
    }
}

// Decided by a user selecting an option.
Permission_Decision_User :: struct {
    // Selected option id.
    option_id:      string,

    // Pre-computed classification of the option.
    kind:           Permission_Option_Kind,

    // Human-readable option label.
    label:          string,

    // Decision epoch ms.
    resolved_at_ms: u64,

    // Client that decided.
    decided_by:     Client,
}

// Decided by a matched persisted rule.
Permission_Decision_Rule :: struct {
    // Rule that matched.
    rule_id:        Rule_Id,

    // Rule label.
    label:          string,

    // Decision epoch ms.
    resolved_at_ms: u64,
}

// Who answered a permission request, and how. Non-owning.
Permission_Decision :: union {
    Permission_Decision_User,
    Permission_Decision_Rule,
}

// Write internally-tagged JSON with `type` first.
permission_decision_emit :: proc(e: ^Emitter, self: Permission_Decision) {
    object_begin(e)

    switch v in self {
    case Permission_Decision_User:
        field_string(e, "type", "user")
        field_string(e, "option_id", v.option_id)
        field_string(e, "kind", permission_option_kind_to_wire(v.kind))
        field_string(e, "label", v.label)
        field_u64(e, "resolved_at_ms", v.resolved_at_ms)
        key(e, "decided_by")
        client_emit(e, v.decided_by)

    case Permission_Decision_Rule:
        field_string(e, "type", "rule")
        field_id(e, "rule_id", ([16]u8)(v.rule_id))
        field_string(e, "label", v.label)
        field_u64(e, "resolved_at_ms", v.resolved_at_ms)
    }

    object_end(e)
}

// Verify annotated field bounds.
permission_decision_validate :: proc(self: Permission_Decision) -> Validation_Error {
    switch v in self {
    case Permission_Decision_User:
        enforce_bounded(32, v.option_id) or_return
        enforce_bounded(256, v.label) or_return
        return client_validate(v.decided_by)

    case Permission_Decision_Rule:
        enforce_id(([16]u8)(v.rule_id)) or_return
        return enforce_bounded(256, v.label)
    }

    return .None
}

// Deep-copy into `allocator`.
permission_decision_clone :: proc(self: Permission_Decision, allocator := context.allocator) -> Permission_Decision {
    switch v in self {
    case Permission_Decision_User:
        return Permission_Decision_User {
            option_id = strings.clone(v.option_id, allocator),
            kind = v.kind,
            label = strings.clone(v.label, allocator),
            resolved_at_ms = v.resolved_at_ms,
            decided_by = client_clone(v.decided_by, allocator),
        }

    case Permission_Decision_Rule:
        return Permission_Decision_Rule {
            rule_id = v.rule_id,
            label = strings.clone(v.label, allocator),
            resolved_at_ms = v.resolved_at_ms,
        }
    }

    return nil
}

// Local-only lifecycle data folded into tool state. Never a broadcast.
Permission_State :: struct {
    // When the daemon issued the prompt.
    requested_at_ms: u64,

    // Options offered to the user. Absent for rule-resolved decisions; at most 32.
    options:         Maybe([]Permission_Option),

    // Once resolved, the recorded decision.
    decision:        Maybe(Permission_Decision),
}

// Verify annotated field bounds on any nested options and decision.
permission_state_validate :: proc(self: Permission_State) -> Validation_Error {
    _, has_opts := self.options.?
    _, has_dec := self.decision.?

    if has_opts == has_dec {
        return .Mismatched_Payload
    }

    if opts, ok := self.options.?; ok {
        if len(opts) > LIMITS.max_permission_options {
            return .Overflow
        }

        for opt in opts {
            permission_option_validate(opt) or_return
        }
    }

    if dec, ok := self.decision.?; ok {
        return permission_decision_validate(dec)
    }

    return .None
}

// Deep-copy into `allocator`.
permission_state_clone :: proc(self: Permission_State, allocator := context.allocator) -> Permission_State {
    out := Permission_State {
        requested_at_ms = self.requested_at_ms,
    }

    if opts, ok := self.options.?; ok {
        cloned := make([]Permission_Option, len(opts), allocator)
        for i in 0 ..< len(cloned) {
            cloned[i] = permission_option_clone(opts[i], allocator)
        }

        out.options = cloned
    }

    // Assign only when a decision is present. Wrapping a bare (nil) `Permission_Decision`
    // union into the `Maybe` field would spuriously mark the decision present. A local
    // `Maybe(Permission_Decision)` (the obvious alternative) crashes the compiler backend.
    if dec, ok := self.decision.?; ok {
        out.decision = permission_decision_clone(dec, allocator)
    }

    return out
}

// A remembered "allow always" answer, scoped to a workspace.
Permission_Rule :: struct {
    // Rule id. @fixed 16
    id:            Rule_Id,

    // If non-null, rule is scoped to one session.
    session_id:    Maybe(Session_Id),

    // Tool name this rule applies to. @bounded 128
    tool:          string,

    // Human-readable rule label. @bounded 256
    label:         string,

    // Creation epoch ms.
    created_at_ms: u64,

    // Client that created the rule.
    created_by:    Client,
}

// Write a permission rule as a JSON object, omitting `session_id` when absent.
permission_rule_emit :: proc(e: ^Emitter, self: Permission_Rule) {
    object_begin(e)
    field_id(e, "id", ([16]u8)(self.id))

    if sid, ok := self.session_id.?; ok {
        field_id(e, "session_id", ([16]u8)(sid))
    }

    field_string(e, "tool", self.tool)
    field_string(e, "label", self.label)
    field_u64(e, "created_at_ms", self.created_at_ms)
    key(e, "created_by")
    client_emit(e, self.created_by)
    object_end(e)
}

// Verify annotated field bounds.
permission_rule_validate :: proc(self: Permission_Rule) -> Validation_Error {
    enforce_id(([16]u8)(self.id)) or_return

    if sid, ok := self.session_id.?; ok {
        enforce_id(([16]u8)(sid)) or_return
    }

    enforce_bounded(128, self.tool) or_return
    enforce_bounded(256, self.label) or_return

    return client_validate(self.created_by)
}

// Deep-copy into `allocator`.
permission_rule_clone :: proc(self: Permission_Rule, allocator := context.allocator) -> Permission_Rule {
    return Permission_Rule {
        id = self.id,
        session_id = self.session_id,
        tool = strings.clone(self.tool, allocator),
        label = strings.clone(self.label, allocator),
        created_at_ms = self.created_at_ms,
        created_by = client_clone(self.created_by, allocator),
    }
}

// Params for permission.decide.
Permission_Decide_Params :: struct {
    // Owning session.
    session_id: Session_Id,

    // Message the permission prompt belongs to.
    message_id: Message_Id,

    // Part the permission prompt belongs to.
    part_id:    Part_Id,

    // @bounded 32
    option_id:  string,
}

// Write permission.decide params.
permission_decide_params_emit :: proc(e: ^Emitter, self: Permission_Decide_Params) {
    object_begin(e)
    field_id(e, "session_id", ([16]u8)(self.session_id))
    field_u64(e, "message_id", u64(self.message_id))
    field_u64(e, "part_id", u64(self.part_id))
    field_string(e, "option_id", self.option_id)
    object_end(e)
}

// Verify annotated field bounds.
permission_decide_params_validate :: proc(self: Permission_Decide_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return

    return enforce_bounded(32, self.option_id)
}

// Params for permission.rules.
Permission_Rules_Params :: struct {
    // Workspace to list rules for.
    workspace_id: Workspace_Id,
}

// Write permission.rules params.
permission_rules_params_emit :: proc(e: ^Emitter, self: Permission_Rules_Params) {
    object_begin(e)
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    object_end(e)
}

// Result of permission.rules.
Permission_Rules_Result :: struct {
    // Remembered rules for the requested workspace. At most 4096.
    rules: []Permission_Rule,
}

// Write a permission.rules result.
permission_rules_result_emit :: proc(e: ^Emitter, self: Permission_Rules_Result) {
    object_begin(e)
    key(e, "rules")
    array_begin(e)
    for rule in self.rules {
        elem(e)
        permission_rule_emit(e, rule)
    }

    array_end(e)
    object_end(e)
}

// Verify annotated field bounds.
permission_rules_result_validate :: proc(self: Permission_Rules_Result) -> Validation_Error {
    if len(self.rules) > LIMITS.max_permission_rules {
        return .Overflow
    }

    for rule in self.rules {
        permission_rule_validate(rule) or_return
    }

    return .None
}

// Params for permission.forget.
Permission_Forget_Params :: struct {
    // Workspace the rule belongs to.
    workspace_id: Workspace_Id,

    // Rule to forget.
    rule_id:      Rule_Id,
}

// Write permission.forget params.
permission_forget_params_emit :: proc(e: ^Emitter, self: Permission_Forget_Params) {
    object_begin(e)
    field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    field_id(e, "rule_id", ([16]u8)(self.rule_id))
    object_end(e)
}

// Verify annotated field bounds.
permission_forget_params_validate :: proc(self: Permission_Forget_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.workspace_id)) or_return

    return enforce_id(([16]u8)(self.rule_id))
}

// --- streaming decoders ---

// Decode a permission option straight from the token stream.
permission_option_from_reader :: proc(d: ^Decoder) -> (opt: Permission_Option, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Kind,
        Label,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            opt.id = dec_string(d) or_return
            seen += {.Id}

        case "kind":
            opt.kind = dec_enum(d, permission_option_kind_wire) or_return
            seen += {.Kind}

        case "label":
            opt.label = dec_string(d) or_return
            seen += {.Label}

        case "creates":
            if !dec_is_null(d) {
                opt.creates = dec_array(d, dec_string) or_return
            }

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Kind, .Label} {
        return {}, .Mismatched_Payload
    }

    return opt, .None
}

// Decode internally-tagged JSON straight from the token stream (any member order).
permission_decision_from_reader :: proc(d: ^Decoder) -> (dec: Permission_Decision, err: Validation_Error) {
    dec_object_begin(d) or_return
    tag := dec_find_tag(d, "type") or_return

    switch tag {
    case "user":
        out: Permission_Decision_User

        Field :: enum {
            Oid,
            Kind,
            Label,
            Res,
            Db,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "option_id":
                out.option_id = dec_string(d) or_return
                seen += {.Oid}

            case "kind":
                out.kind = dec_enum(d, permission_option_kind_wire) or_return
                seen += {.Kind}

            case "label":
                out.label = dec_string(d) or_return
                seen += {.Label}

            case "resolved_at_ms":
                out.resolved_at_ms = dec_u64(d) or_return
                seen += {.Res}

            case "decided_by":
                out.decided_by = client_from_reader(d) or_return
                seen += {.Db}

            case "rule_id":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Oid, .Kind, .Label, .Res, .Db} {
            return nil, .Mismatched_Payload
        }

        return out, .None

    case "rule":
        out: Permission_Decision_Rule

        Field :: enum {
            Rid,
            Label,
            Res,
        }

        seen: bit_set[Field]
        for {
            k, kdone := dec_key(d) or_return
            if kdone do break

            switch k {
            case "rule_id":
                out.rule_id = Rule_Id(dec_fixed(d, 16) or_return)
                seen += {.Rid}

            case "label":
                out.label = dec_string(d) or_return
                seen += {.Label}

            case "resolved_at_ms":
                out.resolved_at_ms = dec_u64(d) or_return
                seen += {.Res}

            case "option_id", "kind", "decided_by":
                return nil, .Mismatched_Payload

            case:
                dec_skip(d) or_return
            }
        }

        if seen != {.Rid, .Label, .Res} {
            return nil, .Mismatched_Payload
        }

        return out, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a permission rule straight from the token stream.
permission_rule_from_reader :: proc(d: ^Decoder) -> (rule: Permission_Rule, err: Validation_Error) {
    dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Tool,
        Label,
        Created,
        By,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            rule.id = Rule_Id(dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "session_id":
            if !dec_is_null(d) {
                rule.session_id = Session_Id(dec_fixed(d, 16) or_return)
            }

        case "tool":
            rule.tool = dec_string(d) or_return
            seen += {.Tool}

        case "label":
            rule.label = dec_string(d) or_return
            seen += {.Label}

        case "created_at_ms":
            rule.created_at_ms = dec_u64(d) or_return
            seen += {.Created}

        case "created_by":
            rule.created_by = client_from_reader(d) or_return
            seen += {.By}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Tool, .Label, .Created, .By} {
        return {}, .Mismatched_Payload
    }

    return rule, .None
}

// Decode permission.decide params straight from the token stream.
permission_decide_params_from_reader :: proc(
    d: ^Decoder,
) -> (
    params: Permission_Decide_Params,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Pid,
        Oid,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            params.message_id = Message_Id(dec_u64(d) or_return)
            seen += {.Mid}

        case "part_id":
            params.part_id = Part_Id(dec_u64(d) or_return)
            seen += {.Pid}

        case "option_id":
            params.option_id = dec_string(d) or_return
            seen += {.Oid}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Pid, .Oid} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode permission.rules params straight from the token stream.
permission_rules_params_from_reader :: proc(d: ^Decoder) -> (params: Permission_Rules_Params, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            params.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return params, .None
}

// Decode a permission.rules result straight from the token stream.
permission_rules_result_from_reader :: proc(d: ^Decoder) -> (result: Permission_Rules_Result, err: Validation_Error) {
    dec_object_begin(d) or_return
    have := false
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "rules":
            result.rules = dec_array(d, permission_rule_from_reader) or_return
            have = true

        case:
            dec_skip(d) or_return
        }
    }

    if !have {
        return {}, .Mismatched_Payload
    }

    return result, .None
}

// Decode permission.forget params straight from the token stream.
permission_forget_params_from_reader :: proc(
    d: ^Decoder,
) -> (
    params: Permission_Forget_Params,
    err: Validation_Error,
) {
    dec_object_begin(d) or_return

    Field :: enum {
        Wid,
        Rid,
    }

    seen: bit_set[Field]
    for {
        k, done := dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            params.workspace_id = Workspace_Id(dec_fixed(d, 16) or_return)
            seen += {.Wid}

        case "rule_id":
            params.rule_id = Rule_Id(dec_fixed(d, 16) or_return)
            seen += {.Rid}

        case:
            dec_skip(d) or_return
        }
    }

    if seen != {.Wid, .Rid} {
        return {}, .Mismatched_Payload
    }

    return params, .None
}
