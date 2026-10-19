//! The checks of each query against the migrated schema, and the types that the checks find.

use std::path::Path;

use crate::Error;
use crate::parse::{self, Field, QueryDeclaration};

/// The checked queries of one query file.
#[derive(Debug)]
pub(crate) struct Module {
    pub(crate) name: String,
    pub(crate) queries: Vec<Query>,
}

/// A row struct and its fields, in column order.
#[derive(Debug)]
pub(crate) struct RowType {
    pub(crate) name: String,
    pub(crate) fields: Vec<Column>,
}

/// A field of a row struct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Column {
    pub(crate) name: String,
    /// The Rust type, in `Option` when the annotation has `?`.
    pub(crate) rust_type: String,
}

/// A checked query.
#[derive(Debug)]
pub(crate) struct Query {
    pub(crate) name: String,
    pub(crate) doc: Vec<String>,
    pub(crate) sql: String,
    /// The parameters, in the order of the annotation.
    pub(crate) parameters: Vec<Parameter>,
    /// The row struct, or `None` for a query without columns.
    pub(crate) row: Option<RowType>,
}

/// A parameter of a query.
#[derive(Debug)]
pub(crate) struct Parameter {
    pub(crate) name: String,
    /// The argument type of the annotation, without `Option`.
    pub(crate) rust_type: String,
    pub(crate) nullable: bool,
}

/// Check each query of `parsed`, the content of `file`, against the schema of `connection`.
pub(crate) fn resolve(
    connection: &rusqlite::Connection,
    file: &Path,
    parsed: &[QueryDeclaration],
) -> Result<Module, Error> {
    let name = file
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| parse::is_field_name(stem))
        .ok_or_else(|| Error::File {
            file: file.to_owned(),
            message: "the file name is not a module name in snake_case".to_owned(),
        })?
        .to_owned();
    let mut queries = Vec::new();
    for declaration in parsed {
        let fail = |message: String| Error::Query {
            file: file.to_owned(),
            query: declaration.name.clone(),
            message,
        };
        let statement = connection
            .prepare(&declaration.sql)
            .map_err(|error| fail(format!("SQLite rejects the SQL: {error}")))?;
        let parameters = parameters(&statement, declaration).map_err(fail)?;
        let row = if statement.column_count() == 0 {
            if !declaration.columns.is_empty() {
                return Err(fail(
                    "the query returns no column, so it has no row. Remove the part after `:`.".to_owned(),
                ));
            }
            None
        } else {
            Some(RowType {
                name: pascal_case(&declaration.name),
                fields: columns(&statement, &declaration.columns).map_err(fail)?,
            })
        };
        queries.push(Query {
            name: declaration.name.clone(),
            doc: declaration.doc.clone(),
            sql: declaration.sql.clone(),
            parameters,
            row,
        });
    }
    Ok(Module { name, queries })
}

/// The parameters of `statement`, in the order of their annotations. Each parameter of the SQL has a `:name` and an
/// annotation with a type, and each annotation names a parameter.
fn parameters(statement: &rusqlite::Statement<'_>, declaration: &QueryDeclaration) -> Result<Vec<Parameter>, String> {
    let mut names = Vec::new();
    for index in 1..=statement.parameter_count() {
        match statement.parameter_name(index).and_then(|name| name.strip_prefix(':')) {
            Some(name) => names.push(name),
            None => return Err(format!("parameter {index} has no name. Write it as `:name`.")),
        }
    }
    for annotation in &declaration.parameters {
        if !names.contains(&annotation.name.as_str()) {
            return Err(format!(
                "the annotation `{}` names no parameter. Remove it, or use `:{}` in the SQL.",
                annotation.name, annotation.name
            ));
        }
    }
    for name in &names {
        if !declaration.parameters.iter().any(|annotation| annotation.name == *name) {
            return Err(format!(
                "the parameter `:{name}` needs an annotation with its type, for example `--! {} ({name}: i64)`",
                declaration.name
            ));
        }
    }
    declaration
        .parameters
        .iter()
        .map(|annotation| {
            let rust_type = annotation.rust_type.clone().ok_or_else(|| {
                format!(
                    "the parameter `{0}` needs a type, for example `{0}: i64` or `{0}: &str`",
                    annotation.name
                )
            })?;
            Ok(Parameter {
                name: annotation.name.clone(),
                rust_type,
                nullable: annotation.nullable,
            })
        })
        .collect()
}

/// The row fields of `statement`, in column order. Each returned column has one field declaration.
fn columns(statement: &rusqlite::Statement<'_>, annotations: &[Field]) -> Result<Vec<Column>, String> {
    let names = statement.column_names();
    for annotation in annotations {
        if !names.contains(&annotation.name.as_str()) {
            return Err(format!(
                "the annotation `{}` names no column. Remove it, or select a column of that name.",
                annotation.name
            ));
        }
    }
    let mut fields = Vec::new();
    for (index, name) in names.iter().enumerate() {
        if !parse::is_field_name(name) {
            return Err(format!(
                "the column `{name}` is not a Rust name in snake_case. Name it with `AS name`, for example \
                 `SELECT count(*) AS count`."
            ));
        }
        if names[..index].contains(name) {
            return Err(format!(
                "the column `{name}` appears twice. Give each returned column a different name with `AS name`."
            ));
        }
        let annotation = annotations
            .iter()
            .find(|annotation| annotation.name == *name)
            .ok_or_else(|| {
                format!(
                    "the column `{name}` has no field declaration. Add `{name}` to the row declaration after `:`. \
                     Declare every returned column."
                )
            })?;
        let nullable = annotation.nullable;
        let origin = origin(statement, index)?;
        let base = match annotation.rust_type.clone() {
            Some(rust_type) => rust_type,
            None => origin
                .as_ref()
                .and_then(|origin| default_type(origin.declared.as_deref()))
                .ok_or_else(|| {
                    format!(
                        "the column `{name}` needs a type, because SQLite reports none for it. \
                         Add a type to its field declaration, for example `{name}: i64`."
                    )
                })?
                .to_owned(),
        };
        if !nullable && origin.is_some_and(|origin| origin.can_be_null) {
            return Err(format!(
                "the column `{name}` can be NULL in the schema. Mark its field declaration with `?`, \
                 for example `{name}?`. Or add `NOT NULL` to the column in the schema."
            ));
        }
        fields.push(Column {
            name: (*name).to_owned(),
            rust_type: if nullable { format!("Option<{base}>") } else { base },
        });
    }
    Ok(fields)
}

/// The Rust type of a column declared as `declared`. `ANY` and other declarations have none, so their columns need
/// a type annotation.
fn default_type(declared: Option<&str>) -> Option<&'static str> {
    let declared = declared?;
    [
        ("INTEGER", "i64"),
        ("REAL", "f64"),
        ("TEXT", "String"),
        ("BLOB", "Vec<u8>"),
    ]
    .into_iter()
    .find(|(name, _)| name.eq_ignore_ascii_case(declared))
    .map(|(_, rust_type)| rust_type)
}

/// The table column that a query column reads.
struct Origin {
    /// The declared type, for example `INTEGER`.
    declared: Option<String>,
    /// Whether the schema lets the column be `NULL`.
    can_be_null: bool,
}

/// The table column of column `index` of `statement`, or `None` for a computed column. Only a `NOT NULL` constraint
/// makes a column non-null. SQLite's rule for a primary key that holds no `NULL` has exceptions, so a schema writes
/// `NOT NULL` on its key columns.
fn origin(statement: &rusqlite::Statement<'_>, index: usize) -> Result<Option<Origin>, String> {
    let metadata = statement
        .column_metadata(index)
        .map_err(|error| format!("SQLite gives no metadata for column {index}: {error}"))?;
    let Some((_, _, _, declared, _, not_null, _, _)) = metadata else {
        return Ok(None);
    };
    Ok(Some(Origin {
        declared: declared.map(|declared| declared.to_string_lossy().into_owned()),
        can_be_null: !not_null,
    }))
}

/// `note_by_id` as `NoteById`.
pub(crate) fn pascal_case(name: &str) -> String {
    name.split('_')
        .map(|word| {
            let mut characters = word.chars();
            characters.next().map_or_else(String::new, |first| {
                first.to_ascii_uppercase().to_string() + characters.as_str()
            })
        })
        .collect()
}
