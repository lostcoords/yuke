package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "src:client"
import "src:wire"

// A refresh fetches models.dev over the network on the daemon, so allow more time than
// the daemon's own transfer budget.
CATALOG_REQUEST_TIMEOUT :: 90 * time.Second

Catalog_Action :: enum {
    Refresh,
    List,
}

catalog_run :: proc() -> int {
    args := os.args[2:]
    action: Catalog_Action
    switch {
    case len(args) == 1 && args[0] == "refresh":
        action = .Refresh

    case len(args) == 1 && args[0] == "list":
        action = .List

    case:
        fmt.eprintln("usage: yuke catalog refresh | list")
        return 2
    }

    return daemon_session_run("yuke catalog", CATALOG_REQUEST_TIMEOUT, catalog_on_ready, &action)
}

catalog_on_ready :: proc(s: ^Daemon_Session) {
    switch (^Catalog_Action)(s.user)^ {
    case .Refresh:
        daemon_session_send(s, .Catalog_Refresh, wire.Empty{}, catalog_on_response)

    case .List:
        daemon_session_send(s, .Catalog_List, wire.Catalog_List_Params{}, catalog_on_response)
    }
}

catalog_on_response :: proc(c: ^client.Client, outcome: client.Request_Outcome, _: rawptr) {
    s, result, ok := daemon_session_result(c, outcome)
    if ok {
        switch (^Catalog_Action)(s.user)^ {
        case .Refresh:
            catalog_refresh_print(result.(wire.Catalog_Refresh_Result))

        case .List:
            catalog_list_print(result.(wire.Catalog_List_Result))
        }
    }

    client.client_close(c)
}

catalog_list_print :: proc(result: wire.Catalog_List_Result) {
    full, is_full := result.(wire.Catalog_List_Result_Full)
    if !is_full {
        fmt.println("catalog unchanged")
        return
    }

    revision := ([64]u8)(full.catalog_rev)
    fmt.printfln("%d model(s); revision %s", len(full.models), string(revision[:]))
    for model in full.models {
        levels := strings.join(model.reasoning_levels, ",", context.temp_allocator)
        fmt.printfln(
            "  %s\tctx=%d\tout=%d\tlevels=[%s]",
            model.id,
            model.context_window,
            model.max_output_tokens,
            levels,
        )
    }

    if message, present := full.health.load_error.?; present {
        fmt.printfln("  load error: %s", message)
    }
    for skipped in full.health.skipped {
        fmt.printfln("  skipped %s", skipped.provider)
    }
}

catalog_refresh_print :: proc(result: wire.Catalog_Refresh_Result) {
    revision := ([64]u8)(result.catalog_rev)
    fmt.printfln("catalog refreshed; revision %s", string(revision[:]))

    if message, present := result.health.load_error.?; present {
        fmt.printfln("  load error: %s", message)
    }
    for skipped in result.health.skipped {
        reason := "invalid config"
        #partial switch _ in skipped.reason {
        case wire.Skip_Reason_Missing_Credential:
            reason = "missing credential"
        }
        fmt.printfln("  skipped %s: %s", skipped.provider, reason)
    }
}
