<script setup>
import { withBase } from 'vitepress';
import { repository } from './project.js';
import { scene } from './frames.js';
import Terminal from './Terminal.vue';

const bundled = ['chat', 'sessions', 'bar', 'toasts', 'themes', 'compaction', 'plugins'];
const plugins = [
  ['btw', 'Side questions that leave the main conversation as it is.'],
  ['mailbox', 'Messages between open yuke sessions on the same machine.'],
  ['subagents', 'New agents with their own context that report back.'],
  ['titles', 'Short session titles from a model that you pick.'],
  ['vim', 'Vim editing in the composer.'],
];

const guard = `import { generateText, Output } from "yuke:ai";
import type { SessionContext } from "yuke:plugins";

const verdict = Output.object({
  schema: {
    type: "object",
    properties: {
      allow: { type: "boolean" },
      reason: { type: "string" },
    },
    required: ["allow", "reason"],
  },
});

export function session(s: SessionContext): undefined {
  const requests: string[] = [];
  s.hook("input.before", (event) => {
    if (event.source.kind !== "user") return undefined;
    for (const block of event.blocks) {
      if ("user_text" in block) requests.push(block.user_text);
    }
    return undefined;
  });
  s.hook("tool.before", async (event) => {
    if (event.call.name !== "exec") return undefined;
    const answer = await generateText({
      model: { provider: "anthropic", model: "claude-haiku-4-5" },
      instructions: "Allow only what the user asked for.",
      prompt: JSON.stringify({ requests, call: event.call.arguments }),
      output: verdict,
      abortSignal: event.signal,
    });
    if (answer.output.allow) return undefined;
    return { block: answer.output.reason };
  });
  return undefined;
}`;
</script>

<template>
  <section class="yours yuke-section" aria-labelledby="yours-title">
    <h2 id="yours-title" class="yuke-heading">Everything you see is a plugin.</h2>
    <p class="intro">
      The chat, the session browser, the status bar, and the notices are TypeScript plugins.
      Turn one off and put your own in its place.
    </p>
    <ul class="bundled" aria-label="Bundled plugins">
      <li v-for="name in bundled" :key="name">{{ name }}</li>
    </ul>

    <div class="pair">
      <div>
        <h3>Add plugins from Git</h3>
        <p>yuke locks each plugin at a commit. An update shows the new commits and asks before it applies them.</p>
        <ul class="catalog">
          <li v-for="[name, text] in plugins" :key="name">
            <code>{{ name }}</code>
            <span>{{ text }}</span>
          </li>
        </ul>
        <pre class="command"><span aria-hidden="true">$ </span>yuke plugin add {{ repository }}-plugins --folder plugins/vim</pre>
      </div>
      <Terminal :scene="scene('plugins')" label="/plugins" trim />
    </div>

    <div class="example">
      <div class="example-copy">
        <h3>Or write your own</h3>
        <p>
          yuke runs every tool call by default. This example plugin asks a small model to check each command against
          what you asked for, and blocks the rest.
        </p>
        <a :href="withBase('/docs/first-plugin')">Your first plugin <span aria-hidden="true">→</span></a>
      </div>
      <pre class="code"><code>{{ guard }}</code></pre>
    </div>
  </section>
</template>

<style scoped>
.yours {
  margin-top: 140px;
  margin-bottom: 120px;
}

h2 {
  max-width: 760px;
  margin: 0 auto;
  font-size: clamp(32px, 4.4vw, 52px);
  text-align: center;
  text-wrap: balance;
}

.intro {
  max-width: 640px;
  margin: 16px auto 0;
  color: var(--vp-c-text-2);
  font-size: 18px;
  line-height: 1.6;
  text-align: center;
}

.bundled {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 8px;
  margin: 24px 0 0;
  padding: 0;
  list-style: none;
}

.bundled li {
  padding: 4px 12px;
  border: 1px solid var(--yuke-line);
  border-radius: 999px;
  color: var(--vp-c-text-2);
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
}

h3 {
  margin: 0;
  color: var(--vp-c-text-1);
  font-size: 20px;
  font-weight: 650;
  letter-spacing: -0.02em;
}

p {
  color: var(--vp-c-text-2);
  font-size: 16px;
  line-height: 1.65;
}

.pair {
  display: grid;
  grid-template-columns: minmax(0, 5fr) minmax(0, 6fr);
  gap: 56px;
  align-items: center;
  max-width: 1080px;
  margin: 72px auto 0;
}

.pair p {
  margin: 10px 0 0;
}

.catalog {
  display: grid;
  gap: 8px;
  margin: 18px 0 0;
  padding: 0;
  list-style: none;
}

.catalog li {
  display: grid;
  grid-template-columns: 96px minmax(0, 1fr);
  gap: 12px;
  font-size: 15px;
}

.catalog code {
  color: var(--vp-c-brand-1);
  font-family: var(--vp-font-family-mono);
  font-size: 14px;
}

.catalog span {
  color: var(--vp-c-text-2);
}

.command,
.code {
  margin: 20px 0 0;
  padding: 14px 16px;
  overflow-x: auto;
  border: 1px solid var(--yuke-line);
  border-radius: 8px;
  background: var(--vp-c-bg-soft);
  color: var(--vp-c-text-1);
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  line-height: 1.6;
}

.command span {
  color: var(--vp-c-brand-1);
}

.example {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 24px;
  max-width: 1080px;
  margin: 96px auto 0;
}

.example-copy {
  grid-column: 1 / -1;
  max-width: 640px;
}

.example-copy p {
  margin: 10px 0 0;
}

.example-copy a {
  display: inline-block;
  margin-top: 12px;
  color: var(--vp-c-brand-1);
  font-size: 14px;
  font-weight: 500;
  text-decoration: none;
}

.example .code {
  margin: 0;
  font-size: 12px;
}

@media (max-width: 860px) {
  .pair,
  .example {
    grid-template-columns: minmax(0, 1fr);
  }
}
</style>
