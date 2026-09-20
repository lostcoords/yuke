-- A goal is session-scoped prompt state. Keeping it separate from the activity
-- log makes updating it immediate without manufacturing a transcript message.
CREATE TABLE session_goals (
    session_id BLOB PRIMARY KEY CHECK (length(session_id) = 16)
        REFERENCES sessions(id) ON DELETE CASCADE,
    goal TEXT NOT NULL CHECK (length(CAST(goal AS BLOB)) <= 1048576)
) STRICT, WITHOUT ROWID;
