-- name: Append_Event :exec
-- session_id: wire.Session_Id!
-- seq: wire.Seq!
-- name: string!
-- payload: string!
INSERT INTO events(session_id, seq, name, payload)
    VALUES (:session_id, :seq, :name, :payload);

-- name: Advance_Seq :exec
-- Contiguity lives in the update predicate: a gap or replay matches nothing.
-- This runs before the insert so every high-water divergence is Seq_Conflict.
-- One `:seq` feeds both sides, so the two can never drift apart.
-- session_id: wire.Session_Id!
-- seq: wire.Seq!
UPDATE sessions SET seq_high = :seq
    WHERE id = :session_id AND seq_high = :seq - 1;

-- name: Bump_Ids :exec
-- Marks only rise; a stale bump is a no-op rather than a rewind.
-- session_id: wire.Session_Id!
-- message_id_high: wire.Message_Id!
-- run_id_high: wire.Run_Id!
-- input_id_high: wire.Input_Id!
-- config_rev_high: wire.Config_Rev!
UPDATE sessions SET
    message_id_high = MAX(message_id_high, :message_id_high),
    run_id_high     = MAX(run_id_high, :run_id_high),
    input_id_high   = MAX(input_id_high, :input_id_high),
    config_rev_high = MAX(config_rev_high, :config_rev_high)
    WHERE id = :session_id;

-- name: Read_High :manual
-- Struct-only: a session that was never written recovers as zeros, which
-- `read_one` can't express (it errors on zero rows). `high_water` reads this
-- manually and defaults on an empty result.
-- session_id: wire.Session_Id!
-- seq_high: wire.Seq!
-- message_id_high: wire.Message_Id!
-- run_id_high: wire.Run_Id!
-- input_id_high: wire.Input_Id!
-- config_rev_high: wire.Config_Rev!
SELECT seq_high, message_id_high, run_id_high, input_id_high, config_rev_high
    FROM sessions WHERE id = :session_id;
