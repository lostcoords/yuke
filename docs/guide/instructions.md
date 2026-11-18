---
description: Give the model project instructions with AGENTS.md, and reusable instructions with skills.
---

# AGENTS.md and skills

The default prompt of a new session contains base instructions, the `AGENTS.md` files, a skill catalog, and environment facts. A session keeps the prompt of its creation. A change to `AGENTS.md` or to a skill applies to the next new session.

## AGENTS.md

yuke reads two files and adds each one that exists to the model instructions:

1. `~/.agents/AGENTS.md`, the global file.
2. `AGENTS.md` in the folder of the session, the workspace file.

The workspace file overrides the global file where they conflict. yuke does not read `AGENTS.md` files in parent folders or in subfolders. When both paths name the same file, yuke includes it once, as the workspace file. A file that exists but that yuke cannot read is an error.

Use `AGENTS.md` for the rules of a project, such as its build commands and its code style.

An instruction is not a sandbox. A request such as “Do not change files” is an instruction to the model, not a limit on its tools.

## Skills

A skill is a folder with a `SKILL.md` file. The file starts with YAML front matter between `---` lines:

```markdown
---
name: pdf
description: Read and fill PDF forms.
---

The steps of the skill.
```

- `name` is optional and defaults to the folder name. It has 1 to 64 characters from `a-z`, `0-9`, and `-`. It does not start or end with `-` and has no `--`.
- `description` is required and has at most 1024 characters.

The name, description, and location of each skill appear in the catalog, sorted by name. The model reads a matching skill through the `read` tool.

The skill catalog includes these sources, in this order:

1. The workspace `.agents/skills`.
2. The user's `~/.agents/skills`.
3. The `skills` folder of each profile plugin.

Each skill is a direct subfolder of a source. A subfolder without a `SKILL.md` file is not a skill, and yuke skips it. yuke also skips a skill whose file has no front matter, has a bad name or description, or has a name that an earlier skill holds, and it tells you why. An earlier source hides a later skill with the same name.

## Change the prompt from a plugin

Use the `prompt.build` hook to add session policy without replacing the default sections. See [Engine hooks](engine.md#change-input-prompt-or-results).
