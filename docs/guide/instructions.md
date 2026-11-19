---
description: Give the model project instructions with AGENTS.md, and reusable instructions with skills.
---

# AGENTS.md and skills

A new session builds its prompt from base instructions, the `AGENTS.md` files, a skill catalog, and environment facts. A session keeps the prompt of its creation. A change to `AGENTS.md` or to a skill applies to the next new session.

## AGENTS.md

yuke adds each of these files that exists to the model instructions:

1. `~/.agents/AGENTS.md`, the global file.
2. `AGENTS.md` in the folder of the session, the workspace file.

The workspace file overrides the global file where they conflict. yuke does not read `AGENTS.md` files in parent folders or in subfolders. A file that exists but that yuke cannot read is an error.

Use `AGENTS.md` for the rules of a project, such as its build commands and its code style.

## Skills

A skill is a folder with a `SKILL.md` file. The file starts with YAML front matter between `---` lines:

```markdown
---
name: pdf
description: Read and fill PDF forms.
---

The steps of the skill.
```

| Field | Rule |
|---|---|
| `name` | Any text that is not empty. It defaults to the folder name. It does not need to match the folder name. |
| `description` | Required. It has at most 1024 characters. |

The front matter holds `key: value` lines. A value can be plain, quoted, or a block (`|` or `>`). yuke ignores other keys.

The name, description, and location of each skill appear in the prompt. The model reads a matching skill through the `read` tool.

yuke scans these folders, in this order:

1. The workspace `.agents/skills`.
2. The user's `~/.agents/skills`.
3. The `skills` folder of each plugin, in load order. A plugin can have only this folder. See [Plugin manifest](plugins.md#plugin-manifest).

Each skill is a direct subfolder. An earlier folder hides a later skill with the same name. yuke skips a skill when:

- the file has no front matter,
- the name is empty,
- the description is missing or has more than 1024 characters, or
- an earlier skill has the same name.

A skipped skill gives a warning notice when the session starts: "yuke skipped the skill at PATH: REASON". The other skills stay.

## Change the prompt from a plugin

Use the `prompt.build` hook to add session policy without replacing the default sections. See [Engine hooks](engine.md#change-input-prompt-or-results).
