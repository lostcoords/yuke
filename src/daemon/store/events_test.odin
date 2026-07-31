package store

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

import "libs:sqlite"
import "libs:testsupport"
import "src:wire"

@(test)
test_append_recovers_across_restart :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "restart")
    defer testsupport.sqlite_db_remove(path)

    alpha := test_session(0xa1)
    beta := test_session(0xb2)

    s, err := open(path)
    testing.expect_value(t, err, nil)

    // Interleaved so neither session's numbering can borrow the other's.
    testing.expect_value(t, event_append(s, alpha, 1, .Run_Started, `{"seq":1}`, {run_id = 1}), nil)
    testing.expect_value(t, event_append(s, beta, 1, .Run_Started, `{"seq":1}`, {run_id = 1}), nil)
    testing.expect_value(
        t,
        event_append(s, alpha, 2, .Message_Committed, `{"seq":2}`, {message_id = 7, input_id = 5}),
        nil,
    )
    testing.expect_value(t, event_append(s, beta, 2, .Config_Changed, `{"seq":2}`, {config_rev = 3}), nil)
    // A stale mark in a later append cannot rewind a family.
    testing.expect_value(t, event_append(s, alpha, 3, .Run_Done, `{"seq":3}`, {message_id = 1, run_id = 1}), nil)

    before_alpha, ba_err := high_water(s, alpha)
    testing.expect_value(t, ba_err, nil)
    before_beta, bb_err := high_water(s, beta)
    testing.expect_value(t, bb_err, nil)

    close(s)

    reopened, reopen_err := open(path)
    testing.expect_value(t, reopen_err, nil)
    defer close(reopened)

    // (a) marks survive the restart exactly.
    after_alpha, aa_err := high_water(reopened, alpha)
    testing.expect_value(t, aa_err, nil)
    testing.expect_value(t, after_alpha, before_alpha)
    testing.expect_value(t, after_alpha.seq, wire.Seq(3))
    testing.expect_value(t, after_alpha.run_id, wire.Run_Id(1))
    testing.expect_value(t, after_alpha.message_id, wire.Message_Id(7))
    testing.expect_value(t, after_alpha.input_id, wire.Input_Id(5))

    after_beta, ab_err := high_water(reopened, beta)
    testing.expect_value(t, ab_err, nil)
    testing.expect_value(t, after_beta, before_beta)
    testing.expect_value(t, after_beta.seq, wire.Seq(2))
    testing.expect_value(t, after_beta.config_rev, wire.Config_Rev(3))

    // (b) the next append continues from the recovered mark, and only from it.
    testing.expect_value(
        t,
        event_append(reopened, alpha, 3, .Run_Done, `{"replay":true}`, {}),
        Store_Error.Seq_Conflict,
    )
    testing.expect_value(t, event_append(reopened, alpha, 5, .Run_Done, `{"gap":true}`, {}), Store_Error.Seq_Conflict)
    testing.expect_value(t, event_append(reopened, alpha, 4, .Run_Done, `{"seq":4}`, {}), nil)

    // (c) the tail reads back whole and in order.
    events, events_err := events_after(reopened, alpha, 0, 16)
    testing.expect_value(t, events_err, nil)
    defer events_destroy(events)

    testing.expect_value(t, len(events), 4)
    for e, i in events {
        testing.expect_value(t, e.seq, wire.Seq(i + 1))
    }

    testing.expect_value(t, events[0].name, wire.Broadcast_Name.Run_Started)
    testing.expect_value(t, events[1].name, wire.Broadcast_Name.Message_Committed)
    testing.expect_value(t, events[1].payload, `{"seq":2}`)
    testing.expect_value(t, events[3].payload, `{"seq":4}`)
}

@(test)
test_deleted_tail_does_not_reclaim_seq :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "rewind")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0xc3)

    s, err := open(path)
    testing.expect_value(t, err, nil)

    for seq in wire.Seq(1) ..= 4 {
        testing.expect_value(t, event_append(s, session, seq, .Run_Done, `{"n":0}`, {}), nil)
    }

    // A truncating rewind deletes rows; the mark is not a MAX(seq) derivation.
    testing.expect_value(t, sqlite.exec(s.writer, "DELETE FROM events WHERE seq >= 3"), sqlite.Result.Ok)
    close(s)

    reopened, reopen_err := open(path)
    testing.expect_value(t, reopen_err, nil)
    defer close(reopened)

    hw, hw_err := high_water(reopened, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.seq, wire.Seq(4))

    // The deleted numbers are spent: only 5 continues the log.
    testing.expect_value(t, event_append(reopened, session, 3, .Run_Done, `{"n":3}`, {}), Store_Error.Seq_Conflict)
    testing.expect_value(t, event_append(reopened, session, 4, .Run_Done, `{"n":4}`, {}), Store_Error.Seq_Conflict)
    testing.expect_value(t, event_append(reopened, session, 5, .Run_Done, `{"n":5}`, {}), nil)

    events, events_err := events_after(reopened, session, 0, 16)
    testing.expect_value(t, events_err, nil)
    defer events_destroy(events)

    testing.expect_value(t, len(events), 3)
    testing.expect_value(t, events[2].seq, wire.Seq(5))
}

@(test)
test_failed_append_leaves_the_mark_untouched :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "rollback")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0xd4)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, event_append(s, session, 1, .Run_Started, `{"n":1}`, {run_id = 9}), nil)

    // Same seq, so the high-water guard rejects the replay before any row is
    // inserted and the transaction unwinds.
    testing.expect_value(t, event_append(s, session, 1, .Run_Done, `{"n":1}`, {run_id = 99}), Store_Error.Seq_Conflict)

    hw, hw_err := high_water(s, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.seq, wire.Seq(1))
    testing.expect_value(t, hw.run_id, wire.Run_Id(9))

    // A gap likewise leaves no event or id mark behind.
    testing.expect_value(t, event_append(s, session, 3, .Run_Done, `{"n":3}`, {run_id = 42}), Store_Error.Seq_Conflict)

    after, after_err := high_water(s, session)
    testing.expect_value(t, after_err, nil)
    testing.expect_value(t, after, hw)

    events, events_err := events_after(s, session, 0, 16)
    testing.expect_value(t, events_err, nil)
    defer events_destroy(events)

    testing.expect_value(t, len(events), 1)
}

@(test)
test_unwritten_session_recovers_as_zero :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "fresh")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    hw, hw_err := high_water(s, test_session(0xe5))
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw, High_Water{})

    events, events_err := events_after(s, test_session(0xe5), 0, 16)
    testing.expect_value(t, events_err, nil)
    defer events_destroy(events)

    testing.expect_value(t, len(events), 0)
}

@(test)
test_tail_read_honors_from_seq_and_limit :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "tail")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0xf6)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    for seq in wire.Seq(1) ..= 6 {
        // `{` opens a format directive, so the brace arrives as an argument.
        payload := fmt.tprintf(`%s%d}`, `{"n":`, seq)
        testing.expect_value(t, event_append(s, session, seq, .Run_Done, payload, {}), nil)
    }

    page, page_err := events_after(s, session, 2, 3)
    testing.expect_value(t, page_err, nil)
    defer events_destroy(page)

    testing.expect_value(t, len(page), 3)
    testing.expect_value(t, page[0].seq, wire.Seq(3))
    testing.expect_value(t, page[0].payload, `{"n":3}`)
    testing.expect_value(t, page[2].seq, wire.Seq(5))

    // Cloned rows outlive the statement that produced them.
    tail, tail_err := events_after(s, session, 5, 8)
    testing.expect_value(t, tail_err, nil)
    defer events_destroy(tail)

    testing.expect_value(t, len(tail), 1)
    testing.expect_value(t, tail[0].seq, wire.Seq(6))
    testing.expect_value(t, page[0].payload, `{"n":3}`)

    past, past_err := events_after(s, session, 6, 8)
    testing.expect_value(t, past_err, nil)
    defer events_destroy(past)

    testing.expect_value(t, len(past), 0)
}

@(test)
test_unknown_stored_name_fails_the_read :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "unknown-name")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x28)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, event_append(s, session, 1, .Run_Started, `{"n":1}`, {}), nil)

    // A row a newer daemon could have written: the name is not in this binary's
    // closed broadcast set, so the read refuses rather than inventing a variant.
    insert := fmt.tprintf(
        "INSERT INTO events(session_id, seq, name, payload) VALUES (x'%s', 2, 'session.teleported', '{}')",
        hex_session(session),
    )
    testing.expect_value(t, sqlite.exec(s.writer, insert), sqlite.Result.Ok)

    events, events_err := events_after(s, session, 0, 16)
    testing.expect_value(t, events_err, Store_Error.Invalid_Row)
    testing.expect(t, events == nil, "a refused read returns no rows")

    // The good prefix is still readable on its own.
    prefix, prefix_err := events_after(s, session, 0, 1)
    testing.expect_value(t, prefix_err, nil)
    defer events_destroy(prefix)

    testing.expect_value(t, len(prefix), 1)
    testing.expect_value(t, prefix[0].name, wire.Broadcast_Name.Run_Started)
}

@(test)
test_persisted_values_are_validated_without_asserting :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "invalid-persisted")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x39)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, event_append(s, session, 1, .Run_Started, `{}`, {}), nil)
    testing.expect_value(t, sqlite.exec(s.writer, "PRAGMA ignore_check_constraints=ON"), sqlite.Result.Ok)

    corrupt_high := fmt.tprintf("UPDATE session_meta SET seq_high = -1 WHERE session_id = x'%s'", hex_session(session))
    testing.expect_value(t, sqlite.exec(s.writer, corrupt_high), sqlite.Result.Ok)

    _, high_err := high_water(s, session)
    testing.expect_value(t, high_err, sqlite.Scan_Error.Value_Out_Of_Range)

    restore_high := fmt.tprintf("UPDATE session_meta SET seq_high = 1 WHERE session_id = x'%s'", hex_session(session))
    testing.expect_value(t, sqlite.exec(s.writer, restore_high), sqlite.Result.Ok)

    // This is a known wire name, but it is live-only and must never be replayed.
    testing.expect_value(t, sqlite.exec(s.writer, "UPDATE events SET name = 'message.started'"), sqlite.Result.Ok)

    rows, rows_err := events_after(s, session, 0, 8)
    testing.expect_value(t, rows_err, Store_Error.Invalid_Row)
    testing.expect(t, rows == nil, "a malformed row returns no prefix")

    testing.expect_value(
        t,
        sqlite.exec(s.writer, "UPDATE events SET name = 'run.started', payload = x'7b7d'"),
        sqlite.Result.Ok,
    )

    rows, rows_err = events_after(s, session, 0, 8)
    testing.expect_value(t, rows_err, sqlite.Scan_Error.Storage_Type_Mismatch)
    testing.expect(t, rows == nil, "a non-TEXT payload is refused")

    testing.expect_value(
        t,
        sqlite.exec(s.writer, "UPDATE events SET seq = 'not-an-integer', payload = '{}'"),
        sqlite.Result.Ok,
    )

    rows, rows_err = events_after(s, session, 0, 8)
    testing.expect_value(t, rows_err, sqlite.Scan_Error.Storage_Type_Mismatch)
    testing.expect(t, rows == nil, "a non-INTEGER seq is refused")
}

@(test)
test_schema_rejects_out_of_range_persisted_numbers :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "range-check")
    defer testsupport.sqlite_db_remove(path)

    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    session := test_session(0x4a)
    insert := fmt.tprintf(
        "INSERT INTO events(session_id, seq, name, payload) VALUES (x'%s', -1, 'run.started', '{}')",
        hex_session(session),
    )
    testing.expect_value(t, sqlite.exec(s.writer, insert), sqlite.Result.Constraint)
}

@(test)
test_tail_materialization_oom_leaves_statement_reusable :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "tail-oom")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x5b)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    testing.expect_value(t, event_append(s, session, 1, .Run_Started, `{}`, {}), nil)

    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, context.allocator, 1)
    rows, rows_err := events_after(s, session, 0, 8, testsupport.failing_allocator(&failing))
    testing.expect_value(t, rows_err, sqlite.Scan_Error.Out_Of_Memory)
    testing.expect(t, rows == nil, "OOM returns no partially owned rows")

    recovered, recovered_err := events_after(s, session, 0, 8)
    testing.expect_value(t, recovered_err, nil)
    defer events_destroy(recovered)
    testing.expect_value(t, len(recovered), 1)
}

@(test)
test_event_visitor_allocates_only_owned_payloads :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "event-visitor-allocations")
    defer testsupport.sqlite_db_remove(path)

    session := test_session(0x6c)
    s, err := open(path)
    testing.expect_value(t, err, nil)
    defer close(s)

    for seq in wire.Seq(1) ..= 3 {
        testing.expect_value(t, event_append(s, session, seq, .Run_Started, `{"seq":1}`, {}), nil)
    }

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    visit := Event_Visit_Probe {
        allocator = tracked,
    }
    visited, stopped, visit_err := events_visit_after(s, session, 0, 8, event_visit_probe, &visit, tracked)
    testing.expect_value(t, visit_err, nil)
    testing.expect(t, !stopped, "the probe consumes every row")
    testing.expect_value(t, visited, 3)
    testing.expect_value(t, visit.count, 3)
    testing.expect_value(t, visit.last, wire.Seq(3))
    testing.expect_value(t, track.total_allocation_count, i64(3))
    testing.expect_value(t, len(track.allocation_map), 0)
}

// The store's whole allocating surface under one tracker: open, append, tail read,
// release, and a read that runs out of memory partway through materializing its rows.
@(test)
test_store_lifecycle_leaks_nothing :: proc(t: ^testing.T) {
    path := testsupport.sqlite_db_path(t, "leak-hunt")
    defer testsupport.sqlite_db_remove(path)

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    tracked := mem.tracking_allocator(&track)

    session := test_session(0x7c)
    s, err := open(path, tracked)
    testing.expect_value(t, err, nil)

    testing.expect_value(t, event_append(s, session, 1, .Run_Started, `{"seq":1}`, {run_id = 1}), nil)
    testing.expect_value(t, event_append(s, session, 2, .Run_Done, `{"seq":2}`, {run_id = 1}), nil)

    hw, hw_err := high_water(s, session)
    testing.expect_value(t, hw_err, nil)
    testing.expect_value(t, hw.seq, wire.Seq(2))

    rows, rows_err := events_after(s, session, 0, 8, tracked)
    testing.expect_value(t, rows_err, nil)
    testing.expect_value(t, len(rows), 2)
    events_destroy(rows)

    // The array and the first row's payload clone succeed, then the second row's
    // clone fails: the read must give back the row it had already materialized.
    // `name` is borrowed rather than cloned, so a row costs exactly one allocation.
    failing: testsupport.Failing_Allocator
    testsupport.failing_allocator_init(&failing, tracked, 2)
    partial, partial_err := events_after(s, session, 0, 8, testsupport.failing_allocator(&failing))
    testing.expect_value(t, partial_err, sqlite.Scan_Error.Out_Of_Memory)
    testing.expect(t, partial == nil, "a failed tail read returns nothing")

    close(s)

    testing.expectf(t, len(track.allocation_map) == 0, "expected zero leaks, got %d", len(track.allocation_map))
    testing.expectf(t, len(track.bad_free_array) == 0, "expected zero bad frees, got %d", len(track.bad_free_array))
}

@(private = "file")
Event_Visit_Probe :: struct {
    allocator: mem.Allocator,
    count:     int,
    last:      wire.Seq,
}

@(private = "file")
event_visit_probe :: proc(user: rawptr, event: Event) -> Event_Visit {
    visit := (^Event_Visit_Probe)(user)
    assert(visit != nil, "the event probe needs state")
    assert(event.seq > visit.last, "the event probe receives ordered rows")

    visit.count += 1
    visit.last = event.seq
    delete(event.payload, visit.allocator)

    return .Continue
}

@(private = "file")
hex_session :: proc(session: wire.Session_Id) -> string {
    b := strings.builder_make(context.temp_allocator)
    for byte_ in ([16]u8)(session) {
        fmt.sbprintf(&b, "%02x", byte_)
    }

    return strings.to_string(b)
}

@(private = "file")
test_session :: proc(tag: byte) -> wire.Session_Id {
    id: [16]u8
    for &b, i in id {
        b = tag ~ byte(i)
    }

    return wire.Session_Id(id)
}
