-- The queries of the fixture. They cover the annotations that the generator supports.

--: Note(id: NoteId, author, title, body?)

--! insert_note (author: &str, title: &str, body?: &str)
--- Add a note.
INSERT INTO notes(author, title, body) VALUES (:author, :title, :body);

--! note_by_id (id: NoteId) : Note
--- The note with this id.
SELECT id, author, title, body FROM notes WHERE id = :id;

--! notes_of (author: &str) : Note

--- The notes of this author. A blank line can come before the doc lines.
SELECT title, body, author, id FROM notes WHERE author = :author ORDER BY id;

--! notes_titled (stars: i64, title: Option<&str>) : Note
SELECT id, author, title, body FROM notes WHERE stars >= :stars AND (:title IS NULL OR title = :title);

--! note_count : (count: i64)
SELECT count(*) AS count FROM notes;

--! star_note (id: NoteId)
UPDATE notes SET stars = stars + 1 WHERE id = :id;

--! stars_of (id: NoteId) : (stars)
SELECT stars FROM notes WHERE id = :id;

--! add_note (author: &str, title: &str) : (id: NoteId, pinned)
--- Add a note, and return its id and its `pinned` value.
INSERT INTO notes(author, title) VALUES (:author, :title) RETURNING id, pinned;

--! tagged_titles : (title, tag?)
--- Each note has one row for each tag. A note without a tag has one row with a `NULL` tag. The schema column
--- `tags.name` is `NOT NULL`.
SELECT notes.title, tags.name AS tag FROM notes LEFT JOIN tags ON tags.note = notes.id ORDER BY notes.id;
