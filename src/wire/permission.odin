package wire
import "libs:json"

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

    // Persist a deny rule and reject; its `creates` patterns produce deny rules (mirror of Allow_Always).
    Reject_Always,
}

// Permission_Option_Kind <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
permission_option_kind_wire := [Permission_Option_Kind]string {
    .Allow_Once    = "allow_once",
    .Allow_Session = "allow_session",
    .Allow_Always  = "allow_always",
    .Reject_Once   = "reject_once",
    .Reject_Always = "reject_always",
}

// Wire string for a permission option kind.
permission_option_kind_to_wire :: proc(k: Permission_Option_Kind) -> string {
    return permission_option_kind_wire[k]
}

// Permission option kind for a wire string; ok is false for an unknown kind.
permission_option_kind_from_wire :: proc(s: string) -> (Permission_Option_Kind, bool) {
    return json.enum_from_wire(permission_option_kind_wire, s)
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
    return json.enum_from_wire(denied_by_wire, s)
}

// Whether a remembered permission rule allows or denies the matched call.
Rule_Action :: enum {
    // Rule allows the matched call.
    Allow,

    // Rule denies the matched call.
    Deny,
}

// Rule_Action <-> wire string, indexed by the enum so a missing mapping is visible.
@(rodata)
rule_action_wire := [Rule_Action]string {
    .Allow = "allow",
    .Deny  = "deny",
}

// Wire string for a rule action.
rule_action_to_wire :: proc(a: Rule_Action) -> string {
    return rule_action_wire[a]
}

// Rule action for a wire string; ok is false for an unknown value.
rule_action_from_wire :: proc(s: string) -> (Rule_Action, bool) {
    return json.enum_from_wire(rule_action_wire, s)
}

// One option the daemon proposes for a permission request.
Permission_Option :: struct {
    // @bounded 32
    // Stable option key clients echo back.
    id:      string,

    // Pre-computed classification of this option.
    kind:    Permission_Option_Kind,

    // @bounded 256
    // Human-readable label.
    label:   string,

    // @bounded LIMITS.max_permission_creates
    // Rule shapes produced when chosen (for `allow_always`); each element @bounded 512.
    creates: Maybe([]string),
}

// Verify annotated field bounds.
permission_option_validate :: proc(self: Permission_Option) -> Validation_Error {
    enforce_bounded(32, self.id) or_return
    enforce_bounded(256, self.label) or_return

    if creates, ok := self.creates.?; ok {
        if len(creates) > LIMITS.max_permission_creates do return .Overflow

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
    // @bounded 32
    // Selected option id.
    option_id:      string,

    // Pre-computed classification of the option.
    kind:           Permission_Option_Kind,

    // @bounded 256
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

    // @bounded 256
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
permission_decision_emit :: proc(e: ^json.Emitter, self: Permission_Decision) {
    json.object_begin(e)

    switch v in self {
    case Permission_Decision_User:
        json.field_string(e, "type", "user")
        json.field_string(e, "option_id", v.option_id)
        json.field_string(e, "kind", permission_option_kind_to_wire(v.kind))
        json.field_string(e, "label", v.label)
        json.field_u64(e, "resolved_at_ms", v.resolved_at_ms)
        json.key(e, "decided_by")
        client_emit(e, v.decided_by)

    case Permission_Decision_Rule:
        json.field_string(e, "type", "rule")
        json.field_id(e, "rule_id", ([16]u8)(v.rule_id))
        json.field_string(e, "label", v.label)
        json.field_u64(e, "resolved_at_ms", v.resolved_at_ms)
    }

    json.object_end(e)
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

    // @bounded LIMITS.max_permission_options
    // Options offered to the user. Absent for rule-resolved decisions; at most 32.
    options:         Maybe([]Permission_Option),

    // Once resolved, the recorded decision.
    decision:        Maybe(Permission_Decision),
}

// Verify annotated field bounds on any nested options and decision.
permission_state_validate :: proc(self: Permission_State) -> Validation_Error {
    _, has_opts := self.options.?
    _, has_dec := self.decision.?

    if has_opts == has_dec do return .Mismatched_Payload

    if opts, ok := self.options.?; ok {
        if len(opts) > LIMITS.max_permission_options do return .Overflow

        for opt in opts {
            permission_option_validate(opt) or_return
        }
    }

    if dec, ok := self.decision.?; ok do return permission_decision_validate(dec)

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
    if dec, ok := self.decision.?; ok do out.decision = permission_decision_clone(dec, allocator)

    return out
}

// A remembered "allow always" answer, scoped to a workspace.
Permission_Rule :: struct {
    // @fixed 16
    // Rule id.
    id:            Rule_Id,

    // If non-null, rule is scoped to one session.
    session_id:    Maybe(Session_Id),

    // @bounded 128
    // Tool name this rule applies to.
    tool:          string,

    // @bounded 256
    // Human-readable rule label.
    label:         string,

    // Allow or deny the matched call.
    action:        Rule_Action,

    // Creation epoch ms.
    created_at_ms: u64,

    // Client that created the rule.
    created_by:    Client,
}

// Write a permission rule as a JSON object, omitting `session_id` when absent.
permission_rule_emit :: proc(e: ^json.Emitter, self: Permission_Rule) {
    json.object_begin(e)
    json.field_id(e, "id", ([16]u8)(self.id))

    if sid, ok := self.session_id.?; ok do json.field_id(e, "session_id", ([16]u8)(sid))

    json.field_string(e, "tool", self.tool)
    json.field_string(e, "label", self.label)
    json.field_string(e, "action", rule_action_to_wire(self.action))
    json.field_u64(e, "created_at_ms", self.created_at_ms)
    json.key(e, "created_by")
    client_emit(e, self.created_by)
    json.object_end(e)
}

// Verify annotated field bounds.
permission_rule_validate :: proc(self: Permission_Rule) -> Validation_Error {
    enforce_id(([16]u8)(self.id)) or_return

    if sid, ok := self.session_id.?; ok do enforce_id(([16]u8)(sid)) or_return

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
        action = self.action,
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
    //
    option_id:  string,

    // @bounded LIMITS.max_permission_reject_message_bytes
    // Client-supplied reason, meaningful only when option_id resolves to a reject
    // kind; the daemon routes it into Tool_State_Denied.reason.
    message:    Maybe(string),
}

// Write permission.decide params.
permission_decide_params_emit :: proc(e: ^json.Emitter, self: Permission_Decide_Params) {
    json.object_begin(e)
    json.field_id(e, "session_id", ([16]u8)(self.session_id))
    json.field_u64(e, "message_id", u64(self.message_id))
    json.field_u64(e, "part_id", u64(self.part_id))
    json.field_string(e, "option_id", self.option_id)
    json.field_string_opt(e, "message", self.message)
    json.object_end(e)
}

// Verify annotated field bounds.
permission_decide_params_validate :: proc(self: Permission_Decide_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.session_id)) or_return
    enforce_bounded(32, self.option_id) or_return

    if msg, ok := self.message.?; ok do return enforce_bounded(LIMITS.max_permission_reject_message_bytes, msg)

    return .None
}

// Result of permission.rules.
Permission_Rules_Result :: struct {
    // @bounded LIMITS.max_permission_rules
    // Remembered rules for the requested workspace.
    rules: []Permission_Rule,
}

// Write a permission.rules result.
permission_rules_result_emit :: proc(e: ^json.Emitter, self: Permission_Rules_Result) {
    json.object_begin(e)
    json.key(e, "rules")
    json.array_begin(e)
    for rule in self.rules {
        json.elem(e)
        permission_rule_emit(e, rule)
    }

    json.array_end(e)
    json.object_end(e)
}

// Verify annotated field bounds.
permission_rules_result_validate :: proc(self: Permission_Rules_Result) -> Validation_Error {
    if len(self.rules) > LIMITS.max_permission_rules do return .Overflow

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
permission_forget_params_emit :: proc(e: ^json.Emitter, self: Permission_Forget_Params) {
    json.object_begin(e)
    json.field_id(e, "workspace_id", ([16]u8)(self.workspace_id))
    json.field_id(e, "rule_id", ([16]u8)(self.rule_id))
    json.object_end(e)
}

// Verify annotated field bounds.
permission_forget_params_validate :: proc(self: Permission_Forget_Params) -> Validation_Error {
    enforce_id(([16]u8)(self.workspace_id)) or_return

    return enforce_id(([16]u8)(self.rule_id))
}

// Decode a permission option straight from the token stream.
permission_option_from_reader :: proc(d: ^json.Decoder) -> (opt: Permission_Option, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Kind,
        Label,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            opt.id = json.dec_string(d) or_return
            seen += {.Id}

        case "kind":
            opt.kind = json.dec_enum(d, permission_option_kind_wire) or_return
            seen += {.Kind}

        case "label":
            opt.label = json.dec_string(d) or_return
            seen += {.Label}

        case "creates":
            opt.creates = json.dec_array(d, json.dec_string) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Kind, .Label} do return {}, .Mismatched_Payload

    return opt, .None
}

// Decode internally-tagged JSON straight from the token stream (any member order).
permission_decision_from_reader :: proc(d: ^json.Decoder) -> (dec: Permission_Decision, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return
    tag := json.dec_find_tag(d, "type") or_return

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
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "option_id":
                out.option_id = json.dec_string(d) or_return
                seen += {.Oid}

            case "kind":
                out.kind = json.dec_enum(d, permission_option_kind_wire) or_return
                seen += {.Kind}

            case "label":
                out.label = json.dec_string(d) or_return
                seen += {.Label}

            case "resolved_at_ms":
                out.resolved_at_ms = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
                seen += {.Res}

            case "decided_by":
                out.decided_by = client_from_reader(d) or_return
                seen += {.Db}

            case "rule_id":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if seen != {.Oid, .Kind, .Label, .Res, .Db} do return nil, .Mismatched_Payload

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
            k, kdone := json.dec_key(d) or_return
            if kdone do break

            switch k {
            case "rule_id":
                out.rule_id = Rule_Id(json.dec_fixed(d, 16) or_return)
                seen += {.Rid}

            case "label":
                out.label = json.dec_string(d) or_return
                seen += {.Label}

            case "resolved_at_ms":
                out.resolved_at_ms = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
                seen += {.Res}

            case "option_id", "kind", "decided_by":
                return nil, .Mismatched_Payload

            case:
                json.dec_skip(d) or_return
            }
        }

        if seen != {.Rid, .Label, .Res} do return nil, .Mismatched_Payload

        return out, .None
    }

    return nil, .Mismatched_Payload
}

// Decode a permission rule straight from the token stream.
permission_rule_from_reader :: proc(d: ^json.Decoder) -> (rule: Permission_Rule, err: json.Decode_Error) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Id,
        Tool,
        Label,
        Action,
        Created,
        By,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "id":
            rule.id = Rule_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Id}

        case "session_id":
            rule.session_id = Session_Id(json.dec_fixed(d, 16) or_return)

        case "tool":
            rule.tool = json.dec_string(d) or_return
            seen += {.Tool}

        case "label":
            rule.label = json.dec_string(d) or_return
            seen += {.Label}

        case "action":
            rule.action = json.dec_enum(d, rule_action_wire) or_return
            seen += {.Action}

        case "created_at_ms":
            rule.created_at_ms = json.dec_u64(d, MAX_WIRE_INTEGER) or_return
            seen += {.Created}

        case "created_by":
            rule.created_by = client_from_reader(d) or_return
            seen += {.By}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Id, .Tool, .Label, .Action, .Created, .By} do return {}, .Mismatched_Payload

    return rule, .None
}

// Decode permission.decide params straight from the token stream.
permission_decide_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Permission_Decide_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Sid,
        Mid,
        Pid,
        Oid,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "session_id":
            params.session_id = Session_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Sid}

        case "message_id":
            params.message_id = Message_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Mid}

        case "part_id":
            params.part_id = Part_Id(json.dec_u64(d, MAX_WIRE_INTEGER) or_return)
            seen += {.Pid}

        case "option_id":
            params.option_id = json.dec_string(d) or_return
            seen += {.Oid}

        case "message":
            params.message = json.dec_string(d) or_return

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Sid, .Mid, .Pid, .Oid} do return {}, .Mismatched_Payload

    return params, .None
}

// Decode a permission.rules result straight from the token stream.
permission_rules_result_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    result: Permission_Rules_Result,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return
    have := false
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "rules":
            result.rules = json.dec_array(d, permission_rule_from_reader) or_return
            have = true

        case:
            json.dec_skip(d) or_return
        }
    }

    if !have do return {}, .Mismatched_Payload

    return result, .None
}

// Decode permission.forget params straight from the token stream.
permission_forget_params_from_reader :: proc(
    d: ^json.Decoder,
) -> (
    params: Permission_Forget_Params,
    err: json.Decode_Error,
) {
    json.dec_object_begin(d) or_return

    Field :: enum {
        Wid,
        Rid,
    }

    seen: bit_set[Field]
    for {
        k, done := json.dec_key(d) or_return
        if done do break

        switch k {
        case "workspace_id":
            params.workspace_id = Workspace_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Wid}

        case "rule_id":
            params.rule_id = Rule_Id(json.dec_fixed(d, 16) or_return)
            seen += {.Rid}

        case:
            json.dec_skip(d) or_return
        }
    }

    if seen != {.Wid, .Rid} do return {}, .Mismatched_Payload

    return params, .None
}
