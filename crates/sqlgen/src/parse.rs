//! The grammar of a query file. The parser reads the annotations and collects the SQL text. SQLite checks the SQL.

/// The declarations of one query file, in file order.
#[derive(Debug, Default)]
pub(crate) struct File {
    pub(crate) queries: Vec<QueryDeclaration>,
}

/// A `--!` query with its SQL.
#[derive(Debug)]
pub(crate) struct QueryDeclaration {
    pub(crate) name: String,
    pub(crate) parameters: Vec<Field>,
    /// The column annotations after the `:` of the annotation. A query without `:` has none.
    pub(crate) columns: Vec<Field>,
    pub(crate) doc: Vec<String>,
    pub(crate) sql: String,
}

/// A parameter or a column annotation: `name`, `name?`, `name: Type`, or `name?: Type`.
#[derive(Debug, Clone)]
pub(crate) struct Field {
    pub(crate) name: String,
    pub(crate) nullable: bool,
    pub(crate) rust_type: Option<String>,
}

/// Parse `source`. An error of one line names the line.
pub(crate) fn parse(source: &str) -> Result<File, String> {
    let mut file = File::default();
    let mut open: Option<(QueryDeclaration, Vec<&str>)> = None;
    for (index, line) in source.lines().enumerate() {
        let number = index + 1;
        let at = |message: String| format!("line {number}: {message}");
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("--!") {
            close(&mut file, open.take()).map_err(at)?;
            open = Some((query_declaration(rest).map_err(at)?, Vec::new()));
        } else if let Some((query, sql)) = &mut open {
            // Doc lines can follow blank lines, but not a line of SQL or an ordinary comment.
            let before_sql = sql.iter().all(|line| line.trim().is_empty());
            match trimmed.strip_prefix("---") {
                Some(doc) if before_sql => query.doc.push(doc.to_owned()),
                _ => sql.push(line),
            }
        } else if !trimmed.is_empty() && !trimmed.starts_with("--") {
            return Err(at("SQL text comes before the first `--!` query".to_owned()));
        }
    }
    close(&mut file, open.take())?;
    Ok(file)
}

/// Add the open query to `file` with its SQL. Blank lines at the start and blank or comment lines at the end do not
/// belong to the SQL.
fn close(file: &mut File, open: Option<(QueryDeclaration, Vec<&str>)>) -> Result<(), String> {
    let Some((mut query, lines)) = open else {
        return Ok(());
    };
    let start = lines
        .iter()
        .position(|line| !line.trim().is_empty())
        .unwrap_or(lines.len());
    let end = lines
        .iter()
        .rposition(|line| {
            let line = line.trim();
            !line.is_empty() && !line.starts_with("--")
        })
        .map_or(start, |last| last + 1);
    if start >= end {
        return Err(format!("query `{}` has no SQL", query.name));
    }
    query.sql = lines[start..end].join("\n");
    file.queries.push(query);
    Ok(())
}

/// Parse `name (parameters) : (columns)`, the text after `--!`. Each part after the name is optional.
fn query_declaration(text: &str) -> Result<QueryDeclaration, String> {
    let mut cursor = Cursor(text.trim());
    let name = cursor.name();
    if !is_field_name(name) {
        return Err(format!("`{name}` is not a query name in snake_case"));
    }
    let parameters = cursor.group()?.unwrap_or_default();
    let columns = if cursor.eat(':') {
        cursor
            .group()?
            .ok_or_else(|| "the columns after `:` need parentheses, for example `: (id, title)`".to_owned())?
    } else {
        Vec::new()
    };
    cursor.end()?;
    Ok(QueryDeclaration {
        name: name.to_owned(),
        parameters,
        columns,
        doc: Vec::new(),
        sql: String::new(),
    })
}

/// The rest of an annotation line.
struct Cursor<'a>(&'a str);

impl<'a> Cursor<'a> {
    /// Take the leading word of letters, digits, and `_`.
    fn name(&mut self) -> &'a str {
        let end = self
            .0
            .find(|character: char| !character.is_ascii_alphanumeric() && character != '_')
            .unwrap_or(self.0.len());
        let (name, rest) = self.0.split_at(end);
        self.0 = rest.trim_start();
        name
    }

    /// Take `character` when the rest starts with it.
    fn eat(&mut self, character: char) -> bool {
        match self.0.strip_prefix(character) {
            Some(rest) => {
                self.0 = rest.trim_start();
                true
            }
            None => false,
        }
    }

    /// Take a field list in parentheses, or `None` when the rest does not start with `(`.
    fn group(&mut self) -> Result<Option<Vec<Field>>, String> {
        if !self.0.starts_with('(') {
            return Ok(None);
        }
        let mut depth = 0_usize;
        for (index, character) in self.0.char_indices() {
            match character {
                '(' | '<' | '[' => depth += 1,
                ')' | '>' | ']' => depth = depth.saturating_sub(1),
                _ => {}
            }
            if depth == 0 {
                let inner = &self.0[1..index];
                self.0 = self.0[index + 1..].trim_start();
                return fields(inner).map(Some);
            }
        }
        Err("a `(` has no matching `)`".to_owned())
    }

    fn end(&self) -> Result<(), String> {
        if self.0.is_empty() {
            Ok(())
        } else {
            Err(format!("unexpected text `{}`", self.0))
        }
    }
}

/// Split `text` at the commas outside `<>`, `[]`, and `()`, and parse each field.
fn fields(text: &str) -> Result<Vec<Field>, String> {
    let mut parts = Vec::new();
    let mut depth = 0_usize;
    let mut start = 0;
    for (index, character) in text.char_indices() {
        match character {
            '(' | '<' | '[' => depth += 1,
            ')' | '>' | ']' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                parts.push(&text[start..index]);
                start = index + 1;
            }
            _ => {}
        }
    }
    parts.push(&text[start..]);
    if parts.len() == 1 && parts[0].trim().is_empty() {
        return Ok(Vec::new());
    }
    let fields: Vec<Field> = parts.into_iter().map(field).collect::<Result<_, _>>()?;
    // A second annotation of one name would be ignored or would make a duplicate argument.
    for (index, field) in fields.iter().enumerate() {
        if fields[..index].iter().any(|other| other.name == field.name) {
            return Err(format!("the field `{}` appears twice", field.name));
        }
    }
    Ok(fields)
}

/// Parse `name`, `name?`, `name: Type`, or `name?: Type`.
fn field(text: &str) -> Result<Field, String> {
    let mut cursor = Cursor(text.trim());
    let name = cursor.name();
    if !is_field_name(name) {
        return Err(format!("`{}` is not a field name in snake_case", text.trim()));
    }
    let nullable = cursor.eat('?');
    let rust_type = if cursor.eat(':') {
        let rust_type = cursor.0.trim();
        if rust_type.is_empty() {
            return Err(format!("field `{name}` has `:` but no type"));
        }
        cursor.0 = "";
        Some(rust_type.to_owned())
    } else {
        None
    };
    cursor.end()?;
    Ok(Field {
        name: name.to_owned(),
        nullable,
        rust_type,
    })
}

/// Whether `name` is a `snake_case` Rust name that is not a keyword.
pub(crate) fn is_field_name(name: &str) -> bool {
    name.starts_with(|character: char| character.is_ascii_lowercase())
        && name
            .chars()
            .all(|character| character.is_ascii_lowercase() || character.is_ascii_digit() || character == '_')
        && !KEYWORDS.contains(&name)
}

/// The strict and reserved keywords of Rust 2024 that are lowercase.
const KEYWORDS: &[&str] = &[
    "abstract", "as", "async", "await", "become", "box", "break", "const", "continue", "crate", "do", "dyn", "else",
    "enum", "extern", "false", "final", "fn", "for", "gen", "if", "impl", "in", "let", "loop", "macro", "match", "mod",
    "move", "mut", "override", "priv", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "true",
    "try", "type", "typeof", "unsafe", "unsized", "use", "virtual", "where", "while", "yield",
];
