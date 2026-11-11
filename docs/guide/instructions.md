---
description: Give the model project instructions with AGENTS.md, and reusable instructions with skills.
---

# AGENTS.md and skills

The default prompt contains base instructions, applicable `AGENTS.md` files, a skill catalog, and environment facts.

## AGENTS.md

yuke reads `AGENTS.md` and adds the applicable files to the model instructions. Use it for the rules of a project, such as its build commands and its code style.

An instruction is not a sandbox. A request such as “Do not change files” is an instruction to the model, not a limit on its tools.

## Skills

A skill is a folder with `SKILL.md`. Its name, description, and location appear in the catalog. The model reads a matching skill through the `read` tool.

The skill catalog includes these sources, in this order:

1. The workspace `.agents/skills`.
2. The user's `~/.agents/skills`.
3. The `skills` folder of each profile plugin.

An earlier source hides a later skill with the same name.

## Change the prompt from a plugin

Use the `prompt.build` hook to add session policy without replacing the default sections. See [Engine hooks](engine.md#change-input-prompt-or-results).
