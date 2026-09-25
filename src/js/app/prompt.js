// The default prompt sections. The engine supplies the facts at run start; this plugin writes the text.
import { config } from "yuke:internal/kernel";

/** @import { Context } from "yuke:internal/ext" */
/** @import { PromptBuild, PromptContext, PromptSection as Section } from "./types/ext.js" */

const DEFAULT_BASE = [
  "You are yuke, an assistant for software development.",
  "",
  "Use the available tools to inspect files, run commands, and make changes.",
  "Read the relevant code and project instructions before you edit.",
  "Use evidence from the workspace to answer questions about the project.",
  "Follow existing conventions and keep changes within the requested scope.",
  "Preserve unrelated user changes.",
  "",
  "Complete the requested work unless the user asks only for advice or a plan.",
  "Ask for clarification when a required decision cannot be resolved from the available context.",
  "Verify changes with the relevant checks. Report failures and any checks you could not run.",
  "Never claim that an action succeeded without evidence.",
  "",
  "Keep responses concise and direct.",
  "Give brief progress updates during substantial work.",
  "Explain the result, the verification, and any unresolved issues.",
].join("\n");
const SUMMARIZER = [
  "You are a context summarization assistant. You read a conversation between a user and an AI assistant, and you write one structured summary in the exact format the instructions name.",
  "",
  "Do not continue the conversation. Do not answer any question in it. Write only the summary.",
  "",
].join("\n");
const SUMMARY_FORMAT = [
  "Use this exact format:",
  "",
  "## Goal",
  "[What does the user want? Name each task when the session covers more than one.]",
  "",
  "## Constraints and preferences",
  "- [Each constraint, preference, or requirement the user stated]",
  "- [Or \"(none)\"]",
  "",
  "## Progress",
  "### Done",
  "- [x] [Completed work]",
  "",
  "### In progress",
  "- [ ] [Current work]",
  "",
  "### Blocked",
  "- [What stops the work, if anything]",
  "",
  "## Key decisions",
  "- **[Decision]**: [Short reason]",
  "",
  "## Next steps",
  "1. [What happens next, in order]",
  "",
  "## Critical context",
  "- [Data, examples, or references the next assistant needs]",
  "- [Or \"(none)\"]",
  "",
  "Keep each section short. Keep exact file paths, symbol names, and error messages.",
].join("\n");
const COMPACTION_SUMMARIZE = SUMMARIZER + "The conversation above is the history to summarize. Write a context checkpoint that another assistant uses to continue the work.\n\n" + SUMMARY_FORMAT;
// The engine wraps the earlier summary in `<context_summary>`, so the merge names that block.
const COMPACTION_MERGE = SUMMARIZER + [
  "The conversation above holds the new messages. The <context_summary> block holds the summary of every earlier message.",
  "",
  "Write one summary that replaces both. Rules:",
  "- Keep every fact from the previous summary.",
  "- Add the new progress, decisions, and context from the new messages.",
  "- Move an item from \"In progress\" to \"Done\" when the new messages completed it.",
  "- Update \"Next steps\" against the current state.",
  "- Keep exact file paths, symbol names, and error messages.",
  "- Remove an item only when it no longer applies.",
  "",
].join("\n") + SUMMARY_FORMAT;
const INSTRUCTIONS_LEAD = "Project instructions follow. Explicit user instructions take precedence. Workspace instructions override global instructions where they conflict.";
const SKILLS_LEAD = "Skills are specialized instructions. Load a matching skill by name unless its body is already in the transcript.";

// A value inside a delimited block must never close the block, so the delimiters and line breaks are escaped.
/** @param {string} text @returns {string} */
function escape(text) {
  return text.replace(/[&<>\n\r\t]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\n": "&#10;", "\r": "&#13;", "\t": "&#9;" })[c] || c);
}

// `${workspace}`, `${session_id}`, and `${agent_name}` in a base prompt read the session facts. Any other placeholder stays as written.
/** @param {string} template @param {PromptContext} context @returns {string} */
function expand(template, context) {
  return template.replace(/\$\{(workspace|session_id|agent_name)\}/g, (_, name) => String(context[/** @type {"workspace" | "session_id" | "agent_name"} */ (name)]));
}

/** @param {PromptBuild} build @returns {Section[]} */
function sections(build) {
  const ctx = build.context;
  const seeded = build.sections.find((section) => section.key === "system_prompt");
  const base = seeded ? { key: "system_prompt", text: expand(seeded.text, ctx) } : { key: "base", text: expand(config.systemPrompt ?? DEFAULT_BASE, ctx) };
  const out = [base];
  if (build.instructions.length) {
    const blocks = build.instructions.map((source) => "## AGENTS.md (" + JSON.stringify(source.path).slice(1, -1) + ")\nScope: " + source.scope + ".\n\n" + source.text);
    out.push({ key: "instructions", text: INSTRUCTIONS_LEAD + "\n\n" + blocks.join("\n\n") });
  }
  if (build.skills.length) {
    const rows = build.skills.map((skill) => "  <skill>\n    <name>" + skill.name + "</name>\n    <description>" + escape(skill.description) + "</description>\n  </skill>\n");
    out.push({ key: "skills", text: SKILLS_LEAD + "\n\n<available_skills>\n" + rows.join("") + "</available_skills>" });
  }
  out.push({ key: "environment", text: "<environment>\nworkspace: " + escape(ctx.workspace) + "\noperating_system: " + ctx.operating_system + "\nshell: " + escape(ctx.shell) + "\nsession_start_date_utc: " + ctx.session_start_date_utc + "\n</environment>" });
  return out;
}

// The host activates this plugin before the user entry, so user hooks can replace its sections.
export const prompt = {
  name: "prompt",
  /** @param {Context} ctx */
  apply(ctx) {
    ctx.hook("prompt.build", (build) => ({ replace: { ...build, sections: sections(build) } }));
    ctx.hook("compaction.prompt", (build) => ({ replace: { ...build, prompt: build.mode === "merge" ? COMPACTION_MERGE : COMPACTION_SUMMARIZE } }));
  },
};
