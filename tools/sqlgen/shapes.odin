package sqlgen

// Which generated struct a table's columns feed, and which columns it excludes.
// Column membership is protocol intent — creation skips defaulted columns, a read
// includes them back — so it is declared here, not derived from the schema.
Shape :: struct {
    table:   string,
    name:    string,
    exclude: []string,
}

GENERATED_SHAPES := []Shape {
    {
        table = "sessions",
        name = "Create_Session_Params",
        exclude = {"message_count", "seq_high", "message_id_high", "run_id_high", "input_id_high", "config_rev_high"},
    },
    {
        table = "sessions",
        name = "Session_Row",
        exclude = {"seq_high", "message_id_high", "run_id_high", "input_id_high", "config_rev_high"},
    },
    {table = "messages", name = "Insert_Message_Params", exclude = {}},
    {table = "session_configs", name = "Insert_Config_Params", exclude = {}},
}

// The plain scalar Odin type for a storage class PRAGMA reports, used when no
// annotation overrides it. `INTEGER` is deliberately absent: its Odin type is not
// fixed by storage class — SQLite INTEGER is signed, yet every integer this schema
// stores is a non-negative count, id, or timestamp, and some are distinct wire ids
// — so signedness and wire identity have to be declared, never guessed. An
// unannotated INTEGER column is a hard error at its resolution site, not a silent
// `u64`; only the unambiguous classes fall back here.
scalar_type :: proc(storage: string) -> (odin_type: string, ok: bool) {
    switch storage {
    case "BLOB":
        return "[]byte", true

    case "TEXT":
        return "string", true

    case "REAL":
        return "f64", true
    }

    return "", false
}
