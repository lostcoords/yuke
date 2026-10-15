//! Generated from the query files by `yuke-sqlgen`. Do not edit.

/// The SQL of each migration in number order. The `user_version` of a database counts its applied migrations.
/// A database at `user_version` `n` runs `MIGRATIONS[n..]`.
pub(crate) const MIGRATIONS: &[&str] = &[
    include_str!(r"../migrations/0001_notes.sql"),
    include_str!(r"../migrations/0002_pins.sql"),
    include_str!(r"../migrations/0003_tags.sql"),
];

pub(crate) mod notes {
    use yuke_sql::rusqlite::{Connection, Result, Row};
    use yuke_sql::{FromRow, Query, execute};

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct NoteById {
        pub(crate) id: crate::NoteId,
        pub(crate) author: String,
        pub(crate) title: String,
        pub(crate) body: Option<String>,
    }

    impl FromRow for NoteById {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                id: row.get("id")?,
                author: row.get("author")?,
                title: row.get("title")?,
                body: row.get("body")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct NotesOf {
        pub(crate) title: String,
        pub(crate) body: Option<String>,
        pub(crate) author: String,
        pub(crate) id: crate::NoteId,
    }

    impl FromRow for NotesOf {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                title: row.get("title")?,
                body: row.get("body")?,
                author: row.get("author")?,
                id: row.get("id")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct NotesTitled {
        pub(crate) id: crate::NoteId,
        pub(crate) author: String,
        pub(crate) title: String,
        pub(crate) body: Option<String>,
    }

    impl FromRow for NotesTitled {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                id: row.get("id")?,
                author: row.get("author")?,
                title: row.get("title")?,
                body: row.get("body")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct NoteCount {
        pub(crate) count: i64,
    }

    impl FromRow for NoteCount {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                count: row.get("count")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct StarsOf {
        pub(crate) stars: i64,
    }

    impl FromRow for StarsOf {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                stars: row.get("stars")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct AddNote {
        pub(crate) id: crate::NoteId,
        pub(crate) pinned: i64,
    }

    impl FromRow for AddNote {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                id: row.get("id")?,
                pinned: row.get("pinned")?,
            })
        }
    }

    #[derive(Debug, Clone, PartialEq)]
    pub(crate) struct TaggedTitles {
        pub(crate) title: String,
        pub(crate) tag: Option<String>,
    }

    impl FromRow for TaggedTitles {
        fn from_row(row: &Row<'_>) -> Result<Self> {
            Ok(Self {
                title: row.get("title")?,
                tag: row.get("tag")?,
            })
        }
    }

    #[derive(Debug)]
    pub(crate) struct InsertNoteParams<'a> {
        pub(crate) author: &'a str,
        pub(crate) title: &'a str,
        pub(crate) body: Option<&'a str>,
    }

    /// Add a note.
    pub(crate) fn insert_note(connection: &Connection, params: &InsertNoteParams<'_>) -> Result<usize> {
        execute(
            connection,
            r"INSERT INTO notes(author, title, body) VALUES (:author, :title, :body);",
            &[
                (":author", &params.author),
                (":title", &params.title),
                (":body", &params.body),
            ],
        )
    }

    /// The note with this id.
    pub(crate) fn note_by_id(connection: &Connection, id: crate::NoteId) -> Query<'_, NoteById> {
        Query::new(
            connection,
            r"SELECT id, author, title, body FROM notes WHERE id = :id;",
            &[(":id", &id)],
        )
    }

    /// The notes of this author. A blank line can come before the doc lines.
    pub(crate) fn notes_of<'a>(connection: &'a Connection, author: &str) -> Query<'a, NotesOf> {
        Query::new(
            connection,
            r"SELECT title, body, author, id FROM notes WHERE author = :author ORDER BY id;",
            &[(":author", &author)],
        )
    }

    #[derive(Debug)]
    pub(crate) struct NotesTitledParams<'a> {
        pub(crate) stars: i64,
        pub(crate) title: Option<&'a str>,
    }

    pub(crate) fn notes_titled<'a>(
        connection: &'a Connection,
        params: &NotesTitledParams<'_>,
    ) -> Query<'a, NotesTitled> {
        Query::new(
            connection,
            r"SELECT id, author, title, body FROM notes WHERE stars >= :stars AND (:title IS NULL OR title = :title);",
            &[(":stars", &params.stars), (":title", &params.title)],
        )
    }

    pub(crate) fn note_count(connection: &Connection) -> Query<'_, NoteCount> {
        Query::new(connection, r"SELECT count(*) AS count FROM notes;", &[])
    }

    pub(crate) fn star_note(connection: &Connection, id: crate::NoteId) -> Result<usize> {
        execute(
            connection,
            r"UPDATE notes SET stars = stars + 1 WHERE id = :id;",
            &[(":id", &id)],
        )
    }

    pub(crate) fn stars_of(connection: &Connection, id: crate::NoteId) -> Query<'_, StarsOf> {
        Query::new(connection, r"SELECT stars FROM notes WHERE id = :id;", &[(":id", &id)])
    }

    #[derive(Debug)]
    pub(crate) struct AddNoteParams<'a> {
        pub(crate) author: &'a str,
        pub(crate) title: &'a str,
    }

    /// Add a note, and return its id and its `pinned` value.
    pub(crate) fn add_note<'a>(connection: &'a Connection, params: &AddNoteParams<'_>) -> Query<'a, AddNote> {
        Query::new(
            connection,
            r"INSERT INTO notes(author, title) VALUES (:author, :title) RETURNING id, pinned;",
            &[(":author", &params.author), (":title", &params.title)],
        )
    }

    /// Each note has one row for each tag. A note without a tag has one row with a `NULL` tag. The schema column
    /// `tags.name` is `NOT NULL`.
    pub(crate) fn tagged_titles(connection: &Connection) -> Query<'_, TaggedTitles> {
        Query::new(
            connection,
            r"SELECT notes.title, tags.name AS tag FROM notes LEFT JOIN tags ON tags.note = notes.id ORDER BY notes.id;",
            &[],
        )
    }
}
