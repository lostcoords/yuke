//! The BM25 ranking of the deferred tools.

use yuke_ai::ToolDefinition;

use super::bm25;

/// A tool `name` with `description` and the input schema `schema`.
fn tool(name: &str, description: &str, schema: &str) -> ToolDefinition {
    ToolDefinition {
        name: name.to_owned(),
        description: description.to_owned(),
        input_schema: schema.to_owned(),
        defer_loading: false,
    }
}

// A plural folds to its singular, so a query word finds the other form.
#[test]
fn bm25_matches_the_singular_and_the_plural_of_a_word() {
    let tools = [
        tool("list_entries", "List the entries.", "{}"),
        tool("pack_box", "Pack one box.", "{}"),
        tool("teach_classes", "Teach the classes.", "{}"),
        tool("read_file", "Read a file.", "{}"),
    ];
    let borrowed: Vec<&ToolDefinition> = tools.iter().collect();

    for (query, expected) in [
        ("entry", "list_entries"),
        ("boxes", "pack_box"),
        ("class", "teach_classes"),
        ("files", "read_file"),
    ] {
        let found = bm25(query, &borrowed, 5);

        let names: Vec<&str> = found.iter().map(|tool| tool.name.as_str()).collect();
        assert_eq!(names, [expected], "{query}");
    }
}

#[test]
fn bm25_ranks_word_matches_and_drops_tools_without_one() {
    let tools = [
        tool("read_file", "Read a file.", "{}"),
        tool("list_issues", "List the issues of a repository.", "{}"),
        tool("createIssue", "Create a GitHub issue.", "{}"),
        tool(
            "comment",
            "Add a comment.",
            r#"{"anyOf":[{"type":"object","properties":{"issue_number":{"type":"integer"}}}]}"#,
        ),
    ];
    let borrowed: Vec<&ToolDefinition> = tools.iter().collect();

    let found = bm25("github issue", &borrowed, 5);

    // camelCase splits `createIssue`, and a property under `anyOf` gives `comment` the word `issue`.
    let names: Vec<&str> = found.iter().map(|tool| tool.name.as_str()).collect();
    assert_eq!(names, ["createIssue", "list_issues", "comment"]);
}
