//! Typed SQLite queries. `yuke-sqlgen` generates a function for each query of a `.sql` file. The function binds the
//! parameters and returns a [`Query`], and the caller picks the result shape: [`Query::one`], [`Query::opt`], or
//! [`Query::all`]. A query without columns runs through [`execute`].

pub use rusqlite;

use rusqlite::{CachedStatement, Connection, Row, ToSql};

/// A prepared query with its bound parameters, or the error of its preparation or binding. It reads no row until
/// [`Query::one`], [`Query::opt`], or [`Query::all`]. Each row gives one `T`.
#[must_use = "a query reads no row until one, opt, or all"]
pub struct Query<'a, T> {
    /// The statement with its parameters, or the error of its preparation or binding. The error waits for the call
    /// that reads the rows, so a generated function returns the query directly.
    statement: rusqlite::Result<CachedStatement<'a>>,
    /// Read the value of one row, for example with [`Row::get`].
    read: fn(&Row<'_>) -> rusqlite::Result<T>,
}

impl<T> std::fmt::Debug for Query<'_, T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Query").finish_non_exhaustive()
    }
}

impl<'a, T> Query<'a, T> {
    /// Prepare `sql` on `connection` through the statement cache, and bind each named parameter. Each name starts
    /// with `:`, as in the SQL. `read` gives the value of each row.
    pub fn new(
        connection: &'a Connection,
        sql: &str,
        parameters: &[(&str, &dyn ToSql)],
        read: fn(&Row<'_>) -> rusqlite::Result<T>,
    ) -> Self {
        let statement = connection.prepare_cached(sql).and_then(|mut statement| {
            for (name, value) in parameters {
                statement.raw_bind_parameter(*name, value)?;
            }
            Ok(statement)
        });
        Query { statement, read }
    }

    /// Read the one row of the query.
    ///
    /// # Errors
    ///
    /// Returns [`rusqlite::Error::QueryReturnedNoRows`] when the query has no row, and
    /// [`rusqlite::Error::QueryReturnedMoreThanOneRow`] when it has a second row. Returns the error of SQLite or of
    /// the read otherwise.
    pub fn one(self) -> rusqlite::Result<T> {
        self.opt()?.ok_or(rusqlite::Error::QueryReturnedNoRows)
    }

    /// Read the row of the query, or `None` when the query has no row.
    ///
    /// # Errors
    ///
    /// Returns [`rusqlite::Error::QueryReturnedMoreThanOneRow`] when the query has a second row. Returns the error of
    /// SQLite or of the read otherwise.
    pub fn opt(self) -> rusqlite::Result<Option<T>> {
        let mut statement = self.statement?;
        let mut rows = statement.raw_query();
        let Some(row) = rows.next()? else {
            return Ok(None);
        };
        let value = (self.read)(row)?;
        // The caller asked for at most one row, so a second row is an error, not a row to drop.
        if rows.next()?.is_some() {
            return Err(rusqlite::Error::QueryReturnedMoreThanOneRow);
        }
        Ok(Some(value))
    }

    /// Read each row of the query, in query order.
    ///
    /// # Errors
    ///
    /// Returns the error of SQLite or of the read.
    pub fn all(self) -> rusqlite::Result<Vec<T>> {
        let mut statement = self.statement?;
        let mut rows = statement.raw_query();
        let mut values = Vec::new();
        while let Some(row) = rows.next()? {
            values.push((self.read)(row)?);
        }
        Ok(values)
    }
}

/// Run `sql`, a query without columns, with the named `parameters`, and return the number of changed rows. The
/// statement comes from the statement cache of `connection`.
///
/// # Errors
///
/// Returns the error of SQLite, for example a constraint that the change breaks.
pub fn execute(connection: &Connection, sql: &str, parameters: &[(&str, &dyn ToSql)]) -> rusqlite::Result<usize> {
    connection.prepare_cached(sql)?.execute(parameters)
}
