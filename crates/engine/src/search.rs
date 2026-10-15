//! The search of deferred tools. A deferred tool stays out of the prompt until the model finds it with
//! [`SEARCH_TOOL_NAME`]. On a target with a native search, the result loads the tools that it found. On a bridge
//! target, the result shows their input schemas, and the model calls one through [`TOOL_CALL_NAME`].

use std::collections::HashMap;
use std::sync::{LazyLock, OnceLock};

use yuke_ai::{SEARCH_TOOL_NAME, ToolCall, ToolDefinition, ToolResult};

use crate::tool::{TOOL_CALL_NAME, Toolset, parse_arguments};

/// The term frequency saturation of BM25: a repeated word adds less with each repeat.
const K1: f64 = 1.2;
/// The document length normalization of BM25: a long document counts its words less.
const B: f64 = 0.75;

/// The indices of the tools in `tools` that match `query`, best first, at most `limit`. BM25 ranks the words of the
/// name, the description, and the schema properties of each tool. A tool that shares no word with the query does not
/// match. Equal scores sort by name.
fn bm25(query: &str, tools: &[&ToolDefinition], limit: usize) -> Vec<usize> {
    let documents: Vec<Vec<String>> = tools.iter().map(|tool| tool_words(tool)).collect();
    let mut terms = Vec::new();
    words(query, &mut terms);
    terms.sort_unstable();
    terms.dedup();
    if documents.is_empty() || terms.is_empty() {
        return Vec::new();
    }

    #[expect(clippy::cast_precision_loss, reason = "a catalog holds far fewer than 2^52 words")]
    let average = documents.iter().map(Vec::len).sum::<usize>() as f64 / documents.len() as f64;
    #[expect(clippy::cast_precision_loss, reason = "a catalog holds far fewer than 2^52 tools")]
    let count = documents.len() as f64;
    let frequencies: Vec<HashMap<&str, usize>> = documents
        .iter()
        .map(|document| {
            let mut frequency = HashMap::new();
            for word in document {
                *frequency.entry(word.as_str()).or_insert(0) += 1;
            }
            frequency
        })
        .collect();

    // The whole catalog sets the rarity of a term, so the search computes each rarity once.
    let rarities: Vec<f64> = terms
        .iter()
        .map(|term| {
            #[expect(clippy::cast_precision_loss, reason = "a catalog holds far fewer than 2^52 tools")]
            let containing = frequencies
                .iter()
                .filter(|frequency| frequency.contains_key(term.as_str()))
                .count() as f64;
            (1.0 + (count - containing + 0.5) / (containing + 0.5)).ln()
        })
        .collect();

    let mut scored: Vec<(usize, f64)> = Vec::new();
    for (index, frequency) in frequencies.iter().enumerate() {
        #[expect(clippy::cast_precision_loss, reason = "a tool has far fewer than 2^52 words")]
        let length = documents[index].len() as f64;
        let mut score = 0.0;
        for (term, rarity) in terms.iter().zip(&rarities) {
            let Some(&occurrences) = frequency.get(term.as_str()) else {
                continue;
            };
            #[expect(clippy::cast_precision_loss, reason = "the counts are small")]
            let occurrences = occurrences as f64;
            score += rarity * occurrences * (K1 + 1.0) / (occurrences + K1 * (1.0 - B + B * length / average));
        }
        if score > 0.0 {
            scored.push((index, score));
        }
    }
    scored.sort_by(|left, right| {
        right
            .1
            .total_cmp(&left.1)
            .then_with(|| tools[left.0].name.cmp(&tools[right.0].name))
    });
    scored.into_iter().take(limit).map(|(index, _)| index).collect()
}

/// The words of `tool` for the index. The name counts twice, because a name match says the most.
fn tool_words(tool: &ToolDefinition) -> Vec<String> {
    let mut out = Vec::new();
    words(&tool.name, &mut out);
    words(&tool.name, &mut out);
    words(&tool.description, &mut out);
    if let Ok(schema) = serde_json::from_str::<serde_json::Value>(&tool.input_schema) {
        schema_words(&schema, &mut out);
    }
    out
}

/// Add the property names and descriptions of a JSON schema. Visit each nested value, so a property under `items`,
/// `$defs`, or `anyOf` counts too.
fn schema_words(schema: &serde_json::Value, out: &mut Vec<String>) {
    match schema {
        serde_json::Value::Object(map) => {
            if let Some(properties) = map.get("properties").and_then(serde_json::Value::as_object) {
                for (name, property) in properties {
                    words(name, out);
                    if let Some(description) = property.get("description").and_then(serde_json::Value::as_str) {
                        words(description, out);
                    }
                }
            }
            for value in map.values() {
                schema_words(value, out);
            }
        }
        serde_json::Value::Array(values) => {
            for value in values {
                schema_words(value, out);
            }
        }
        _ => {}
    }
}

/// Split `text` into lowercase words at each character that is not a letter or a digit, and at each camelCase
/// boundary. A word of one character carries no meaning, so it drops out. Each word takes its singular form.
fn words(text: &str, out: &mut Vec<String>) {
    let mut word = String::new();
    let mut after_lowercase = false;
    for character in text.chars() {
        if !character.is_alphanumeric() {
            push_word(&mut word, out);
            after_lowercase = false;
            continue;
        }
        if character.is_uppercase() && after_lowercase {
            push_word(&mut word, out);
        }
        after_lowercase = character.is_lowercase() || character.is_numeric();
        word.extend(character.to_lowercase());
    }
    push_word(&mut word, out);
}

/// Move `word` to `out` in its singular form, unless it has one character.
fn push_word(word: &mut String, out: &mut Vec<String>) {
    if word.chars().nth(1).is_some() {
        out.push(singular(std::mem::take(word)));
    } else {
        word.clear();
    }
}

/// Fold an English plural to its singular, so `issues` matches `issue`. The rules stay naive on purpose: a catalog
/// holds short names and descriptions.
fn singular(mut word: String) -> String {
    // Each suffix is ASCII, so each cut falls on a character boundary.
    let length = word.chars().count();
    if length > 4 && word.ends_with("ies") {
        word.truncate(word.len() - 3);
        word.push('y');
    } else if length > 4
        && ["ches", "shes", "sses", "xes", "zes"]
            .iter()
            .any(|suffix| word.ends_with(suffix))
    {
        word.truncate(word.len() - 2);
    } else if length > 3 && word.ends_with('s') && !word.ends_with("ss") {
        word.truncate(word.len() - 1);
    }
    word
}

/// The default and the maximum count of matches of one search.
const DEFAULT_LIMIT: usize = 5;
const MAX_LIMIT: usize = 20;

/// The arguments of both search tools.
fn search_schema() -> String {
    format!(
        r#"{{"type":"object","properties":{{"query":{{"type":"string","description":"Keywords that describe the tool."}},"limit":{{"type":"integer","minimum":1,"maximum":{MAX_LIMIT},"description":"The most matches. The default is {DEFAULT_LIMIT}."}}}},"required":["query"],"additionalProperties":false}}"#
    )
}

/// The arguments of [`TOOL_CALL_NAME`].
const CALL_SCHEMA: &str = r#"{"type":"object","properties":{"name":{"type":"string","description":"The name of the tool."},"arguments":{"type":"object","description":"The arguments of the tool, as its input schema says."}},"required":["name","arguments"],"additionalProperties":false}"#;

/// The search tool of a target with a native search. A match becomes callable by its name.
static NATIVE_SEARCH: LazyLock<ToolDefinition> = LazyLock::new(|| ToolDefinition {
    name: SEARCH_TOOL_NAME.into(),
    description: "Find more tools. Many tools are not listed here. When no listed tool fits the task, search them by \
         keywords. Each match becomes callable by its name."
        .to_owned(),
    input_schema: search_schema(),
    defer_loading: false,
});

/// The search tool of a target without a native search. A match is callable through [`TOOL_CALL_NAME`].
static BRIDGE_SEARCH: LazyLock<ToolDefinition> = LazyLock::new(|| ToolDefinition {
    name: SEARCH_TOOL_NAME.into(),
    description: "Find more tools. Many tools are not listed here. When no listed tool fits the task, search them by \
         keywords. The result shows each match with its input schema. Call a match with tool_call."
        .to_owned(),
    input_schema: search_schema(),
    defer_loading: false,
});

/// The tool that calls a deferred tool on a target without a native search.
static BRIDGE_CALL: LazyLock<ToolDefinition> = LazyLock::new(|| ToolDefinition {
    name: TOOL_CALL_NAME.into(),
    description: "Call a deferred tool that tool_search found. Pass its name and its arguments.".to_owned(),
    input_schema: CALL_SCHEMA.into(),
    defer_loading: false,
});

/// The search mode for deferred tools.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SearchMode {
    Native,
    Bridge,
}

impl SearchMode {
    pub(crate) fn for_target(target: &yuke_ai::Target) -> Self {
        if target.tool_search {
            SearchMode::Native
        } else {
            SearchMode::Bridge
        }
    }
}

/// The definitions that the requests of one turn declare, built once for each kind of target. Without a deferred
/// tool, they are the toolset's. On a native target, they add the search tool. On another target, they leave out each
/// deferred tool and add the two bridge tools, so a search never changes them.
pub(crate) struct Declared<'a> {
    toolset: &'a Toolset,
    native: OnceLock<Vec<ToolDefinition>>,
    bridge: OnceLock<Vec<ToolDefinition>>,
}

impl<'a> Declared<'a> {
    pub(crate) fn new(toolset: &'a Toolset) -> Self {
        Declared {
            toolset,
            native: OnceLock::new(),
            bridge: OnceLock::new(),
        }
    }

    /// The definitions for a target with a native search, or for another target.
    pub(crate) fn tools(&self, mode: SearchMode) -> &[ToolDefinition] {
        let definitions = self.toolset.definitions();
        if !definitions.iter().any(|definition| definition.defer_loading) {
            return definitions;
        }
        if mode == SearchMode::Native {
            return self.native.get_or_init(|| {
                let mut declared = definitions.to_vec();
                declared.push(NATIVE_SEARCH.clone());
                declared
            });
        }
        self.bridge.get_or_init(|| {
            let mut declared: Vec<ToolDefinition> = definitions
                .iter()
                .filter(|definition| !definition.defer_loading)
                .cloned()
                .collect();
            declared.push(BRIDGE_SEARCH.clone());
            declared.push(BRIDGE_CALL.clone());
            declared
        })
    }
}

/// The arguments of the search tool.
#[derive(serde::Deserialize)]
struct SearchArguments {
    query: String,
    limit: Option<usize>,
}

/// Run the search `call` over the deferred tools of `toolset`. On a native target, the result loads the matches.
/// On another target, it shows them with their input schemas.
pub(crate) fn search(toolset: &Toolset, call: &ToolCall, mode: SearchMode) -> ToolResult {
    let arguments: SearchArguments = match parse_arguments(&call.arguments) {
        Ok(arguments) => arguments,
        Err(error) => return ToolResult::error(&call.call_id, error),
    };
    let limit = arguments.limit.unwrap_or(DEFAULT_LIMIT);
    if !(1..=MAX_LIMIT).contains(&limit) {
        return ToolResult::error(&call.call_id, format!("The limit must be 1 to {MAX_LIMIT}."));
    }
    let deferred: Vec<&ToolDefinition> = toolset.deferred().collect();
    let found: Vec<&ToolDefinition> = bm25(&arguments.query, &deferred, limit)
        .into_iter()
        .map(|index| deferred[index])
        .collect();
    if found.is_empty() {
        return ToolResult::success(
            &call.call_id,
            format!("No deferred tool matches \"{}\".", arguments.query),
        );
    }

    if mode == SearchMode::Native {
        let lines: Vec<String> = found
            .iter()
            .map(|tool| format!("- {}: {}", tool.name, tool.description))
            .collect();
        let text = format!(
            "Loaded {} tools. Call each one by its name:\n{}",
            found.len(),
            lines.join("\n")
        );
        let loaded = found.into_iter().cloned().collect();
        return ToolResult::success(&call.call_id, text).with_loaded(loaded);
    }
    // The engine sets no size cap. A caller bounds a large result in `after_tool`, as for any tool.
    let mut sections = vec![format!("Found {} tools. Call one with tool_call.", found.len())];
    sections.extend(found.into_iter().map(|tool| {
        format!(
            "## {}\n{}\nInput schema: {}",
            tool.name, tool.description, tool.input_schema
        )
    }));
    ToolResult::success(&call.call_id, sections.join("\n\n"))
}

/// The arguments of [`TOOL_CALL_NAME`]. The inner arguments keep their text, so the tool receives the bytes that the
/// model wrote.
#[derive(serde::Deserialize)]
struct CallArguments {
    name: String,
    arguments: Box<serde_json::value::RawValue>,
}

/// The real call that the bridge `call` asks for, under the call id of `call`. The real call goes through the hooks and
/// the toolset as a direct call does, so a name without a tool gets an error result there.
pub(crate) fn unwrap_call(call: &ToolCall) -> Result<ToolCall, ToolResult> {
    let arguments: CallArguments =
        parse_arguments(&call.arguments).map_err(|error| ToolResult::error(&call.call_id, error))?;
    Ok(ToolCall {
        call_id: call.call_id.clone(),
        name: arguments.name,
        arguments: arguments.arguments.get().to_owned(),
    })
}

#[cfg(test)]
mod tests;
