-- Replace persisted report paths with the direct child name.
WITH RECURSIVE sources AS (
    SELECT rowid AS row_id, payload,
        CASE name WHEN 'message.committed' THEN '$.source' ELSE '$.input.source' END AS source
    FROM events WHERE name IN ('message.committed', 'input.queued')
), parts(row_id, source, rest) AS (
    SELECT row_id, source, json_extract(payload, source || '.path') FROM sources
    WHERE json_extract(payload, source || '.type') IN ('child_report', 'child_input_canceled')
        AND json_type(payload, source || '.path') = 'text'
    UNION ALL
    SELECT row_id, source, substr(rest, instr(rest, '/') + 1)
    FROM parts WHERE instr(rest, '/') > 0
), names AS (
    SELECT row_id, source, rest FROM parts WHERE instr(rest, '/') = 0
)
UPDATE events SET payload = (
    SELECT json_remove(json_set(events.payload, source || '.name', rest), source || '.path')
    FROM names WHERE names.row_id = events.rowid
) WHERE rowid IN (SELECT row_id FROM names);

UPDATE pending_inputs SET payload = (
    SELECT json_extract(e.payload, '$.input') FROM events e
    WHERE e.session_id = pending_inputs.session_id AND e.seq = pending_inputs.seq
) WHERE json_extract(payload, '$.source.type') IN ('child_report', 'child_input_canceled');
