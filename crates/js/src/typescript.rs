//! The removal of TypeScript types. `build.rs` includes this file too, so the built-in modules and the user files
//! lose their types the same way.

use std::path::Path;

use oxc_allocator::Allocator;
use oxc_codegen::Codegen;
use oxc_parser::Parser;
use oxc_semantic::SemanticBuilder;
use oxc_span::{LabeledSpan, SourceType};
use oxc_transformer::{TransformOptions, Transformer};

/// Remove the types of the TypeScript module `source`, and return the JavaScript. The output keeps modern syntax. The
/// code generator writes new code, so a line of the output can differ from the line of the source.
pub(crate) fn strip(path: &Path, source: &str) -> Result<String, String> {
    let allocator = Allocator::default();
    let parsed = Parser::new(&allocator, source, SourceType::ts().with_module(true)).parse();
    if parsed.diagnostics.has_errors() {
        return Err(describe(
            path,
            source,
            parsed
                .diagnostics
                .errors()
                .map(|error| (error.labels.first().map(LabeledSpan::offset), &*error.message)),
        ));
    }

    let mut program = parsed.program;
    let built = SemanticBuilder::new_compiler().build(&program);
    if built.diagnostics.has_errors() {
        return Err(describe(
            path,
            source,
            built
                .diagnostics
                .errors()
                .map(|error| (error.labels.first().map(LabeledSpan::offset), &*error.message)),
        ));
    }
    let scoping = built.semantic.into_scoping();

    let transformed =
        Transformer::new(&allocator, path, &TransformOptions::default()).build_with_scoping(scoping, &mut program);
    if transformed.diagnostics.has_errors() {
        return Err(describe(
            path,
            source,
            transformed
                .diagnostics
                .errors()
                .map(|error| (error.labels.first().map(LabeledSpan::offset), &*error.message)),
        ));
    }

    Ok(Codegen::new().build(&program).code)
}

/// One line for each error: the path, the line and column of the error's offset, and its message.
fn describe<'a>(path: &Path, source: &str, errors: impl Iterator<Item = (Option<u32>, &'a str)>) -> String {
    let lines: Vec<String> = errors
        .map(|(offset, message)| match offset {
            Some(offset) => {
                let (line, column) = place(source, offset);
                format!("{}:{line}:{column}: {message}", path.display())
            }
            None => format!("{}: {message}", path.display()),
        })
        .collect();
    lines.join("\n")
}

/// The line and column, both from 1, of the byte `offset` in `source`. The column counts characters.
fn place(source: &str, offset: u32) -> (usize, usize) {
    let before = source.get(..offset as usize).unwrap_or(source);
    let line = before.matches('\n').count() + 1;
    let column = before.rsplit('\n').next().map_or(0, |text| text.chars().count()) + 1;
    (line, column)
}
