# Translate the trusted executable catalog into Rust data.

def hex:
  if . < 16 then . as $n | "0123456789abcdef"[$n:$n + 1]
  else ((. / 16 | floor) | hex) + ((. % 16) | hex)
  end;

# JSON and Rust use different escapes for control characters.
def rust_string:
  "\"" + (explode | map(
    if . == 34 then "\\\""
    elif . == 92 then "\\\\"
    elif . == 10 then "\\n"
    elif . == 13 then "\\r"
    elif . == 9 then "\\t"
    elif . >= 32 and . < 127 then [.] | implode
    else "\\u{" + hex + "}"
    end
  ) | join("")) + "\"";

# A snake-case wire name becomes the camel-case name of its Rust variant.
def variant:
  split("_") | map((.[0:1] | ascii_upcase) + .[1:]) | join("");

def list: "&[" + join(", ") + "]";

# A static row borrows its text and its lists, so it needs no allocation. A row from configuration owns them.
def cow_string: "Cow::Borrowed(" + rust_string + ")";

def cow_list: "Cow::Borrowed(" + list + ")";

def option(f): if . == null then "None" else "Some(" + f + ")" end;

def int: tostring;

# A price is f64, so an integer literal takes a fraction.
def float: tostring | if test("[.eE]") then . else . + ".0" end;

def bool: tostring;

# Modalities are open on the wire. A name this package cannot use stays out.
def modalities:
  map(select(. == "text" or . == "image" or . == "audio" or . == "video" or . == "pdf") | "Modality::" + variant) | cow_list;

# A breakpoint policy names the shape of one protocol, so it marks only that protocol's endpoint.
def cache_breakpoint:
  (.cache == "anthropic_breakpoint" and .protocol == "anthropic_messages")
  or (.cache == "openai_breakpoint" and .protocol == "openai_responses");

def endpoint($auth):
  "Endpoint { protocol: Protocol::" + (.protocol | variant)
  + ", credential_header: " + (if $auth.kind == "oauth" then "Some(CredentialHeader::AuthorizationBearer)"
      elif .key_header == null then "None" else "Some(CredentialHeader::" + (.key_header | variant) + ")" end)
  + ", cache_breakpoint: " + (cache_breakpoint | bool)
  + ", responses_dialect: ResponsesDialect::"
      + (if .protocol == "openai_responses" then .responses_dialect | variant else "Standard" end)
  + ", chat_dialect: ChatDialect::" + (if .protocol == "openai_chat" then .chat_dialect | variant else "Standard" end)
  + " }";

# A level outside the request efforts stays out. A null level means no effort.
def reasoning_level:
  if . == null then "None"
  elif IN("minimal", "low", "medium", "high", "xhigh", "max") then "Some(Effort::" + variant + ")"
  else empty end;

def band:
  "PriceBand { min_prompt_tokens: " + (.min_prompt_tokens // 0 | int)
  + ([("input", "output", "reasoning", "cache_read", "cache_write") as $key |
      ", " + $key + ": " + (.[$key] | option(float))] | join(""))
  + " }";

# The Chat Completions controls nest as the wire settings the request takes.
def dialect:
  "Dialect { chat: ChatFlags { thinking_format: ThinkingFormat::" + (.thinking_format // "none" | variant)
  + ", reasoning_replay: ReasoningReplayMode::" + (.reasoning_replay // "none" | variant)
  + ", max_tokens_field: MaxTokensField::" + (.max_tokens_field // "max_tokens" | variant) + " }"
  + ", anthropic_thinking: AnthropicThinking::"
  + (if .anthropic_thinking == "budget" then
      "Budget { min: " + (.reasoning_budget_min | option(int)) + ", max: " + (.reasoning_budget_max | option(int)) + " }"
     else (.anthropic_thinking // "none" | variant) end)
  + " }";

def model:
  "Model {\n"
  + "id: " + (.id | cow_string) + ",\n"
  + "upstream_id: " + (.upstream_id | cow_string) + ",\n"
  + "name: " + (.name | cow_string) + ",\n"
  + "protocol: Protocol::" + (.protocol | variant) + ",\n"
  + "limits: Limits { context_window: " + (.limits.context_window | option(int))
      + ", max_output_tokens: " + (.limits.max_output_tokens | option(int)) + " },\n"
  + "cost: " + (.cost | map(band) | cow_list) + ",\n"
  + "caps: Caps { tools: " + (.flags.supports_tools | option(bool))
      + ", tool_search: " + (.flags.supports_tool_search | option(bool))
      + ", disable_reasoning: " + (.flags.can_disable_reasoning | option(bool))
      + ", cache_breakpoint: " + (.flags.supports_cache_breakpoint | option(bool)) + " },\n"
  + "reasoning_levels: " + (.reasoning_levels | map(reasoning_level) | cow_list) + ",\n"
  + "dialect: " + (.flags | dialect) + ",\n"
  + "modalities: Modalities { input: " + (.modalities.input | modalities)
      + ", output: " + (.modalities.output | modalities) + " },\n"
  + "}";

def provider:
  "Provider {\n"
  + "id: " + (.id | cow_string) + ",\n"
  + "name: " + (.name | cow_string) + ",\n"
  + "auth: " + (if .auth.kind == "oauth" then
      "Auth::OAuth(Flow::" + (.auth.flow | variant) + ")"
    else "Auth::ApiKey(" + (.auth.env | option(cow_string)) + ")" end) + ",\n"
  + "base_url: " + (.base_url | cow_string) + ",\n"
  + "headers: " + (.headers | map("Header::from_static(" + (.name | rust_string) + ", " + (.value | rust_string) + ")") | cow_list) + ",\n"
  + "session_header: SessionHeader::" + (.session_header | variant) + ",\n"
  + "endpoints: " + (.auth as $auth | .endpoints | map(endpoint($auth)) | cow_list) + ",\n"
  + "models: " + (.models | map(model) | cow_list) + ",\n"
  + "}";

"//! Generated from the Yuke catalog. Do not edit. Run scripts/generate-catalog.sh.\n\n"
+ "use std::borrow::Cow;\n\n"
+ "use crate::catalog::{AnthropicThinking, Auth, Caps, ChatFlags, Dialect, Endpoint, Limits, Modalities, Model, PriceBand, Provider};\n"
+ "use crate::oauth::Flow;\n"
+ "use crate::request::{ChatDialect, Effort, MaxTokensField, Modality, Protocol, ReasoningReplayMode, ResponsesDialect, ThinkingFormat};\n"
+ "use crate::route::{CredentialHeader, SessionHeader};\nuse crate::transport::Header;\n\n"
+ "/// The identifier of this catalog snapshot.\n"
+ "pub const REVISION: &str = " + (.catalog_rev | rust_string) + ";\n\n"
+ "/// The provider table. Each row borrows static storage.\n"
+ "pub static PROVIDERS: &[Provider] = &[\n" + (.providers | map(provider) | join(",\n")) + "\n];\n"
