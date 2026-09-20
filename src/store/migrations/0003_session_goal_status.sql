-- Goals created before lifecycle control existed were active goals.
ALTER TABLE session_goals ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'paused', 'completed'));
