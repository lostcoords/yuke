ALTER TABLE sessions ADD COLUMN name TEXT CHECK (
    (name IS NULL) = (parent_id IS NULL)
    AND (name IS NULL OR (length(name) BETWEEN 1 AND 64
        AND name GLOB '[a-z]*' AND name NOT GLOB '*[^a-z0-9_-]*' AND name <> 'root'))
);
CREATE UNIQUE INDEX sessions_child_name ON sessions(parent_id, name) WHERE name IS NOT NULL;
