//! The BM25 ranking of the deferred tools.

use yuke_ai::ToolDefinition;

use super::bm25;

// A plural folds to its singular, so a query word finds the other form.
#[test]
fn bm25_matches_the_singular_and_the_plural_of_a_word() {
    let tools = [
        ToolDefinition {
            name: "list_entries".to_owned(),
            description: "List the entries.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
        ToolDefinition {
            name: "pack_box".to_owned(),
            description: "Pack one box.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
        ToolDefinition {
            name: "teach_classes".to_owned(),
            description: "Teach the classes.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
        ToolDefinition {
            name: "read_file".to_owned(),
            description: "Read a file.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
    ];
    let borrowed: Vec<&ToolDefinition> = tools.iter().collect();

    for (query, expected) in [
        ("entry", "list_entries"),
        ("boxes", "pack_box"),
        ("class", "teach_classes"),
        ("files", "read_file"),
    ] {
        let found = bm25(query, &borrowed, 5);

        let names: Vec<&str> = found.iter().map(|&index| tools[index].name.as_str()).collect();
        assert_eq!(names, [expected], "{query}");
    }
}

#[test]
fn bm25_ranks_word_matches_and_drops_tools_without_one() {
    let tools = [
        ToolDefinition {
            name: "read_file".to_owned(),
            description: "Read a file.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
        ToolDefinition {
            name: "list_issues".to_owned(),
            description: "List the issues of a repository.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
        ToolDefinition {
            name: "createIssue".to_owned(),
            description: "Create a GitHub issue.".to_owned(),
            input_schema: "{}".to_owned(),
            defer_loading: false,
        },
        ToolDefinition {
            name: "comment".to_owned(),
            description: "Add a comment.".to_owned(),
            input_schema: r#"{"anyOf":[{"type":"object","properties":{"issue_number":{"type":"integer"}}}]}"#
                .to_owned(),
            defer_loading: false,
        },
    ];
    let borrowed: Vec<&ToolDefinition> = tools.iter().collect();

    let found = bm25("github issue", &borrowed, 5);

    // camelCase splits `createIssue`, and a property under `anyOf` gives `comment` the word `issue`.
    let names: Vec<&str> = found.iter().map(|&index| tools[index].name.as_str()).collect();
    assert_eq!(names, ["createIssue", "list_issues", "comment"]);
}
