// Add restricted child-agent kinds to a yuke profile.
import { plugins } from "yuke";
import { agents } from "yuke:plugins";

plugins.use(agents({
  catalog: {
    research: {
      description: "Inspect the requested area and report evidence.",
      model: "provider/model", // Replace this selector, or omit it to use the parent model and level.
      reasoning: "low", // Omit it for the model default. It needs a model.
      prompt: "Do not edit files.",
      tools: ["read", "exec", "skill"],
    },
    edit: {
      description: "Make one focused change and verify it.",
      tools: ["read", "write", "edit", "exec", "skill"],
    },
  },
  default: "research",
  maxDepth: 2,
  maxConcurrent: 4,
  maxRounds: 30,
}));
