//! The Rust text of the checked queries. rustfmt formats it after, so the text only needs to be valid Rust.

use std::fmt::{self, Write as _};

use crate::resolve::{Column, Module, Parameter, Query, pascal_case};

/// The generated file for `modules`. `migrations` holds the migration file names in number order.
pub(crate) fn emit(migrations: &[String], modules: &[Module]) -> Result<String, fmt::Error> {
    let mut code = String::from("//! Generated from the query files by `yuke-sqlgen`. Do not edit.\n\n");
    // `include_str!` finds a path from the file that calls it. The generated file is `src/queries.rs` of the crate.
    code.push_str(
        "/// The SQL of each migration in number order. The `user_version` of a database counts its applied migrations.\n\
         /// A database at `user_version` `n` runs `MIGRATIONS[n..]`.\n\
         pub(crate) const MIGRATIONS: &[&str] = &[",
    );
    for name in migrations {
        write!(code, "include_str!({}),", raw_string(&format!("../migrations/{name}")))?;
    }
    code.push_str("];\n\n");
    for module in modules {
        emit_module(&mut code, module)?;
    }
    Ok(code)
}

fn emit_module(code: &mut String, module: &Module) -> fmt::Result {
    writeln!(code, "pub(crate) mod {} {{", module.name)?;
    // The module imports each name that it uses, so no path in it can be shorter, whatever the parent imports.
    let reads = module.queries.iter().any(|query| !query.columns.is_empty());
    let executes = module.queries.iter().any(|query| query.columns.is_empty());
    let mut runtime = Vec::new();
    let mut sqlite = Vec::new();
    if !module.queries.is_empty() {
        sqlite.push("Connection");
    }
    if reads {
        runtime.push("Query");
    }
    if executes {
        sqlite.push("Result");
        runtime.push("execute");
    }
    for (path, names) in [("yuke_sql", runtime), ("yuke_sql::rusqlite", sqlite)] {
        if !names.is_empty() {
            writeln!(code, "use {path}::{{{}}};", names.join(", "))?;
        }
    }
    code.push('\n');
    // A query of one column gives the value of that column, so only a query of several columns needs a row struct.
    for query in module.queries.iter().filter(|query| query.columns.len() > 1) {
        emit_row(code, &pascal_case(&query.name), &query.columns)?;
    }
    for query in &module.queries {
        emit_query(code, query)?;
    }
    code.push_str("}\n\n");
    Ok(())
}

fn emit_row(code: &mut String, name: &str, columns: &[Column]) -> fmt::Result {
    writeln!(code, "#[derive(Debug, PartialEq)]\npub(crate) struct {name} {{")?;
    for column in columns {
        writeln!(code, "pub(crate) {}: {},", column.name, column.rust_type)?;
    }
    code.push_str("}\n\n");
    Ok(())
}

fn emit_query(code: &mut String, query: &Query) -> fmt::Result {
    let parameter_struct = (query.parameters.len() > 1).then(|| format!("{}Params", pascal_case(&query.name)));
    // A parameter struct with a reference needs a lifetime.
    let borrows = query
        .parameters
        .iter()
        .any(|parameter| parameter.rust_type.contains('&'));
    if let Some(name) = &parameter_struct {
        let lifetime = if borrows { "<'a>" } else { "" };
        writeln!(code, "#[derive(Debug)]\npub(crate) struct {name}{lifetime} {{")?;
        for parameter in &query.parameters {
            writeln!(code, "pub(crate) {}: {},", parameter.name, field_type(parameter))?;
        }
        code.push_str("}\n\n");
    }

    for line in &query.doc {
        writeln!(code, "///{line}")?;
    }
    // The query borrows the connection. Elision covers that when the connection is the only reference argument.
    let other_references = parameter_struct.is_some() || borrows;
    let (value, read) = match query.columns.as_slice() {
        [] => (None, String::new()),
        [column] => (
            Some(column.rust_type.clone()),
            format!(", |row| row.get({:?})", column.name),
        ),
        columns => {
            let name = pascal_case(&query.name);
            let fields: Vec<_> = columns
                .iter()
                .map(|column| format!("{0}: row.get({0:?})?", column.name))
                .collect();
            let read = format!(", |row| Ok({name} {{ {} }})", fields.join(", "));
            (Some(name), read)
        }
    };
    let (lifetime, connection, output) = match &value {
        Some(value) if other_references => ("<'a>", "&'a", format!("Query<'a, {value}>")),
        Some(value) => ("", "&", format!("Query<'_, {value}>")),
        None => ("", "&", "Result<usize>".to_owned()),
    };
    write!(
        code,
        "pub(crate) fn {}{lifetime}(connection: {connection} Connection",
        query.name
    )?;
    let mut bindings = Vec::new();
    match &parameter_struct {
        Some(name) => {
            let lifetime = if borrows { "<'_>" } else { "" };
            write!(code, ", params: &{name}{lifetime}")?;
            for parameter in &query.parameters {
                bindings.push(format!("(\":{0}\", &params.{0})", parameter.name));
            }
        }
        None => {
            for parameter in &query.parameters {
                write!(
                    code,
                    ", {}: {}",
                    parameter.name,
                    nullable(parameter, &parameter.rust_type)
                )?;
                bindings.push(format!("(\":{0}\", &{0})", parameter.name));
            }
        }
    }
    let call = if value.is_some() { "Query::new" } else { "execute" };
    writeln!(
        code,
        ") -> {output} {{\n{call}(connection, {}, &[{}]{read})\n}}\n",
        raw_string(&query.sql),
        bindings.join(", ")
    )
}

/// The type of a parameter as a field of a parameter struct. Each reference without a lifetime borrows for the
/// lifetime of the struct, so `Option<&str>` becomes `Option<&'a str>`.
fn field_type(parameter: &Parameter) -> String {
    let mut rust_type = String::new();
    let mut rest = parameter.rust_type.as_str();
    while let Some(index) = rest.find('&') {
        rust_type.push_str(&rest[..=index]);
        rest = &rest[index + 1..];
        if !rest.trim_start().starts_with('\'') {
            rust_type.push_str("'a ");
        }
    }
    rust_type.push_str(rest);
    nullable(parameter, &rust_type)
}

/// `rust_type` in `Option` when the parameter can be `NULL`.
fn nullable(parameter: &Parameter, rust_type: &str) -> String {
    if parameter.nullable {
        format!("Option<{rust_type}>")
    } else {
        rust_type.to_owned()
    }
}

/// `text` as a raw string literal with the fewest `#` that it needs, so the text keeps its lines and its quotes.
fn raw_string(text: &str) -> String {
    let mut hashes = String::new();
    while text.contains(&format!("\"{hashes}")) {
        hashes.push('#');
    }
    format!("r{hashes}\"{text}\"{hashes}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parameter(rust_type: &str) -> Parameter {
        Parameter {
            name: "value".to_owned(),
            rust_type: rust_type.to_owned(),
            nullable: false,
        }
    }

    #[test]
    fn a_raw_string_keeps_the_sql_with_the_fewest_hashes() {
        assert_eq!(raw_string("SELECT 1"), "r\"SELECT 1\"");
        assert_eq!(raw_string("SELECT \"a\""), "r#\"SELECT \"a\"\"#");
        assert_eq!(raw_string("SELECT \"#"), "r##\"SELECT \"#\"##");
    }

    #[test]
    fn a_parameter_struct_field_borrows_each_reference_without_a_lifetime_for_the_struct() {
        assert_eq!(field_type(&parameter("&str")), "&'a str");
        assert_eq!(field_type(&parameter("Option<&str>")), "Option<&'a str>");
        assert_eq!(field_type(&parameter("&'static str")), "&'static str");
        assert_eq!(field_type(&parameter("i64")), "i64");
    }
}
