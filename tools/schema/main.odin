package schema

import "core:fmt"
import "core:os"
import "core:strings"

Options :: struct {
    wire_dir: string,

    // Where `wire.json` is written, or compared against under `--check`.
    out:      string,

    // Where the JSON Schema document is written.
    schema:   string,

    // Verify the committed artifact instead of rewriting it.
    check:    bool,
    quiet:    bool,
}

main :: proc() {
    opts, args_ok := options_parse(os.args[1:])

    if !args_ok {
        fmt.eprintfln("usage: schema [--wire <dir>] [--out <file>] [--schema-out <file>] [--check] [--quiet]")
        os.exit(2)
    }

    d: Diags
    ps, load_ok := package_load(opts.wire_dir, &d)

    if !load_ok {
        diags_report(&d)
        os.exit(1)
    }

    m: Model
    consts_collect(&m, &ps, &d)
    types_collect(&m, &ps, &d)
    registry_collect(&m, &ps, &d)
    check_bounds(&m, &ps, &d)
    check_references(&m, &d)

    if diags_failed(&d) {
        diags_report(&d)
        os.exit(1)
    }

    artifact := artifact_build(&m)
    data, data_ok := json_encode(artifact)
    document := jsonschema_build(&m)
    check_schema_refs(document, &d)
    schema_data, schema_ok := json_encode(document)

    if !data_ok || !schema_ok {
        fmt.eprintfln("cannot encode the artifacts")
        os.exit(1)
    }

    artifact_emit(data, opts.out, opts.check, &d)
    artifact_emit(schema_data, opts.schema, opts.check, &d)

    if diags_failed(&d) {
        diags_report(&d)
        os.exit(1)
    }

    if !opts.quiet {
        model_report(&m)
        artifact_report(&artifact, opts.out, len(data))
        fmt.printfln("%s  %d bytes", opts.schema, len(schema_data))
    }
}

options_parse :: proc(args: []string) -> (opts: Options, ok: bool) {
    opts.wire_dir = "src/wire"
    opts.out = "schema/wire.json"
    opts.schema = "schema/wire.schema.json"
    i := 0

    for i < len(args) {
        switch args[i] {
        case "--wire":
            if i + 1 >= len(args) {
                return opts, false
            }

            opts.wire_dir = args[i + 1]
            i += 2

        case "--out":
            if i + 1 >= len(args) {
                return opts, false
            }

            opts.out = args[i + 1]
            i += 2

        case "--schema-out":
            if i + 1 >= len(args) {
                return opts, false
            }

            opts.schema = args[i + 1]
            i += 2

        case "--check":
            opts.check = true
            i += 1

        case "--quiet":
            opts.quiet = true
            i += 1

        case:
            return opts, false
        }
    }

    return opts, true
}

// Human-readable summary of what was modelled, printed unless `--quiet`.
model_report :: proc(m: ^Model) {
    assert(m != nil, "model_report needs a model")

    bounded, fixed, unbounded := 0, 0, 0
    required, optional, nullable, tristate := 0, 0, 0, 0

    for s in m.structs {
        for f in s.fields {
            switch f.bound.kind {
            case .Bounded:
                bounded += 1

            case .Fixed:
                fixed += 1

            case .Unbounded:
                unbounded += 1

            case .Missing:
            }

            switch f.presence {
            case .Required:
                required += 1

            case .Optional:
                optional += 1

            case .Defaulted:
                optional += 1

            case .Required_Nullable:
                nullable += 1

            case .Tristate:
                tristate += 1
            }
        }
    }

    fmt.printfln("protocol version   %d", m.protocol_version)
    fmt.printfln("limits             %d", len(m.limits))
    fmt.printfln("constants          %d", len(m.consts))
    fmt.printfln("structs            %d", len(m.structs))
    fmt.printfln("unions             %d", len(m.unions))
    fmt.printfln("enums              %d (wire-mapped)", len(m.enums))
    fmt.printfln("aliases            %d", len(m.aliases))
    fmt.printfln("methods            %d", len(m.methods))
    fmt.printfln("broadcasts         %d", len(m.broadcasts))
    fmt.printfln("errors             %d", len(m.errors))
    fmt.println()
    fmt.printfln("markers            %d bounded, %d fixed, %d unbounded", bounded, fixed, unbounded)
    fmt.printfln(
        "presence           %d required, %d optional, %d required-nullable, %d tristate",
        required,
        optional,
        nullable,
        tristate,
    )

    // Broadcast order, not map order: this line is compared by hand between runs.
    fmt.printf("delivery classes   ")
    seen: map[string]bool
    sep := ""

    for b in m.broadcasts {
        if b.class in seen {
            continue
        }

        seen[b.class] = true
        count := 0

        for other in m.broadcasts {
            if other.class == b.class {
                count += 1
            }
        }

        fmt.printf("%s%d %s", sep, count, b.class)
        sep = ", "
    }

    fmt.println()
}
