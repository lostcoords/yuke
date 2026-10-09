//! The Rust text of the checked queries. rustfmt formats it after, so the text only needs to be valid Rust.

use std::fmt::{self, Write as _};

use crate::resolve::{Module, Parameter, Query, RowType, pascal_case};

/// The generated file for `modules`.
pub(crate) fn emit(modules: &[Module]) -> Result<String, fmt::Error> {
    let mut code = String::from("//! Generated from the query files by `yuke-sqlgen`. Do not edit.\n\n");
    if modules.iter().any(uses_parent) {
        code.push_str("use super::*;\n\n");
    }
    for module in modules {
        emit_module(&mut code, module)?;
    }
    Ok(code)
}

fn emit_module(code: &mut String, module: &Module) -> fmt::Result {
    writeln!(code, "pub(crate) mod {} {{", module.name)?;
    if uses_parent(module) {
        code.push_str("use super::*;\n");
    }
    // The module imports each name that it uses, so no path in it can be shorter, whatever the parent imports.
    let rows = !module.rows.is_empty();
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
    for row in &module.rows {
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
        Some(row) if other_references => ("<'a>", "&'a", format!("Query<'a, {row}>")),
        Some(row) => ("", "&", format!("Query<'_, {row}>")),
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

/// `sql` as a raw string literal with the fewest `#` that it needs, so the SQL keeps its lines and its quotes.
fn raw_string(sql: &str) -> String {
    let mut hashes = String::new();
    while sql.contains(&format!("\"{hashes}")) {
        hashes.push('#');
    }
    format!("r{hashes}\"{sql}\"{hashes}")
}

/// Whether a type of `module` names something of the parent module, so the module needs `use super::*`.
fn uses_parent(module: &Module) -> bool {
    let row_types = module
        .rows
        .iter()
        .flat_map(|row| &row.fields)
        .map(|field| field.rust_type.as_str());
    let parameter_types = module
        .queries
        .iter()
        .flat_map(|query| &query.parameters)
        .map(|parameter| parameter.rust_type.as_str());
    row_types.chain(parameter_types).any(names_parent)
}

/// Whether `rust_type` holds a path whose first segment is not a primitive, a prelude type, a crate root, or a
/// keyword. `NoteId`, `models::NoteId`, and `Option<NoteId>` name the parent. `i64`, `Option<String>`, and
/// `crate::id::NoteId` do not.
fn names_parent(rust_type: &str) -> bool {
    const OWN: &[&str] = &[
        "bool", "char", "str", "i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize",
        "f32", "f64", "String", "Vec", "Option", "Box", "Result", "crate", "std", "core", "alloc", "self", "super",
        "mut", "dyn", "const",
    ];
    let mut paths = Vec::new();
    let mut start = None;
    for (index, character) in rust_type.char_indices().chain([(rust_type.len(), ' ')]) {
        let in_path = character.is_ascii_alphanumeric() || character == '_' || character == ':';
        match (start, in_path) {
            (None, true) => start = Some(index),
            (Some(first), false) => {
                // A lifetime such as `'a` is not a path.
                if !rust_type[..first].ends_with('\'') {
                    paths.push(&rust_type[first..index]);
                }
                start = None;
            }
            _ => {}
        }
    }
    paths.into_iter().any(|path| {
        // A path that starts with `::` is absolute, and a number is an array length.
        let segment = path.split("::").next().unwrap_or_default();
        !path.starts_with("::")
            && !segment.starts_with(|character: char| character.is_ascii_digit())
            && !OWN.contains(&segment)
    })
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
    fn a_type_names_the_parent_when_a_path_starts_outside_the_prelude_and_the_crate_roots() {
        for rust_type in [
            "NoteId",
            "&NoteId",
            "models::NoteId",
            "Option<NoteId>",
            "std::option::Option<NoteId>",
        ] {
            assert!(names_parent(rust_type), "{rust_type}");
        }
        for rust_type in [
            "i64",
            "&str",
            "&'static str",
            "[u8; 16]",
            "Option<String>",
            "Result<i64, String>",
            "crate::id::NoteId",
            "::std::time::Duration",
        ] {
            assert!(!names_parent(rust_type), "{rust_type}");
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
