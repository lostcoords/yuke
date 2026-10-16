//! The Rust text of the checked queries. rustfmt formats it after, so the text only needs to be valid Rust.

use std::fmt::{self, Write as _};

use crate::resolve::{Module, Parameter, Query, RowType, pascal_case};

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
    let rows = module.queries.iter().any(|query| query.row.is_some());
    let executes = module.queries.iter().any(|query| query.row.is_none());
    let mut runtime = Vec::new();
    let mut sqlite = Vec::new();
    if !module.queries.is_empty() {
        sqlite.push("Connection");
    }
    if rows || executes {
        sqlite.push("Result");
    }
    if rows {
        sqlite.push("Row");
        runtime.extend(["FromRow", "Query"]);
    }
    if executes {
        runtime.push("execute");
    }
    for (path, names) in [("yuke_sql", runtime), ("yuke_sql::rusqlite", sqlite)] {
        if !names.is_empty() {
            writeln!(code, "use {path}::{{{}}};", names.join(", "))?;
        }
    }
    code.push('\n');
    for row in module.queries.iter().filter_map(|query| query.row.as_ref()) {
        emit_row(code, row)?;
    }
    for query in &module.queries {
        emit_query(code, query)?;
    }
    code.push_str("}\n\n");
    Ok(())
}

fn emit_row(code: &mut String, row: &RowType) -> fmt::Result {
    writeln!(
        code,
        "#[derive(Debug, Clone, PartialEq)]\npub(crate) struct {} {{",
        row.name
    )?;
    for field in &row.fields {
        writeln!(code, "pub(crate) {}: {},", field.name, field.rust_type)?;
    }
    code.push_str("}\n\n");
    writeln!(
        code,
        "impl FromRow for {} {{\n\
         fn from_row(row: &Row<'_>) -> Result<Self> {{\n\
         Ok(Self {{",
        row.name
    )?;
    for field in &row.fields {
        writeln!(code, "{0}: row.get({0:?})?,", field.name)?;
    }
    code.push_str("})\n}\n}\n\n");
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
    let other_references = parameter_struct.is_some()
        || query
            .parameters
            .iter()
            .any(|parameter| parameter.rust_type.contains('&'));
    let (lifetime, connection, output) = match &query.row {
        Some(row) if other_references => ("<'a>", "&'a", format!("Query<'a, {}>", row.name)),
        Some(row) => ("", "&", format!("Query<'_, {}>", row.name)),
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
    let call = if query.row.is_some() { "Query::new" } else { "execute" };
    writeln!(
        code,
        ") -> {output} {{\n{call}(connection, {}, &[{}])\n}}\n",
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
