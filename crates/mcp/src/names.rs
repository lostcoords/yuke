//! The model name of each MCP tool: `mcp__<server>__<tool>`, in the characters and the length that providers accept.

use yuke_engine::{TOOL_NAME_MAX, tool_name_character};

/// The model name of the tool `tool` of the server `server`. A character that a provider refuses becomes `_`. A name
/// over 64 characters keeps its first 55 characters and adds `_` and 8 hex digits of a hash of the server and the tool.
pub(crate) fn tool_name(server: &str, tool: &str) -> String {
    let name = sanitized(server, tool);
    if name.len() <= TOOL_NAME_MAX {
        return name;
    }
    hashed_name(server, tool)
}

/// The model name of the tool `tool` of the server `server` with the hash, also when the name is short. A tool gets it
/// when an earlier tool has its plain name.
pub(crate) fn hashed_name(server: &str, tool: &str) -> String {
    let name = sanitized(server, tool);
    // The name is ASCII, so the cut falls on a character.
    let kept = &name[..name.len().min(TOOL_NAME_MAX - 9)];
    format!("{kept}_{:08x}", fnv1a(server, tool))
}

/// `mcp__<server>__<tool>`, with `_` for each character that a provider refuses.
fn sanitized(server: &str, tool: &str) -> String {
    format!("mcp__{server}__{tool}")
        .chars()
        .map(|character| if tool_name_character(character) { character } else { '_' })
        .collect()
}

/// The 32-bit FNV-1a hash of `server`, a NUL byte, and `tool`. It is stable across processes, so a saved call names the
/// same tool.
fn fnv1a(server: &str, tool: &str) -> u32 {
    let bytes = server.bytes().chain([0]).chain(tool.bytes());
    bytes.fold(0x811c_9dc5, |hash, byte| {
        (hash ^ u32::from(byte)).wrapping_mul(0x0100_0193)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_name_keeps_its_valid_characters_and_replaces_the_others() {
        assert_eq!(tool_name("git", "status"), "mcp__git__status");
        assert_eq!(tool_name("my server", "read.file"), "mcp__my_server__read_file");
    }

    #[test]
    fn a_long_name_ends_in_a_hash_that_tells_two_long_tools_apart() {
        let tool = "a".repeat(80);
        let first = tool_name("server", &format!("{tool}1"));
        let second = tool_name("server", &format!("{tool}2"));

        assert_eq!(first.len(), 64);
        assert_eq!(second.len(), 64);
        assert_ne!(first, second);
        assert!(first.starts_with("mcp__server__aaa"), "{first}");
    }

    #[test]
    fn a_name_with_the_hash_differs_from_the_plain_name_and_keeps_the_limit() {
        let plain = tool_name("a b", "echo");
        let hashed = hashed_name("a_b", "echo");
        let long = tool_name("server", &"a".repeat(80));

        assert_eq!(plain, "mcp__a_b__echo");
        assert!(
            hashed.starts_with("mcp__a_b__echo_") && hashed.len() == plain.len() + 9,
            "{hashed}"
        );
        assert_eq!(hashed_name("server", &"a".repeat(80)), long);
    }
}
