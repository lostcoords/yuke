<script setup>
import { onMounted, ref } from 'vue';
import { withBase } from 'vitepress';
import { scene } from './frames.js';
import Terminal from './Terminal.vue';

// Mock only: ?layout=rows shows the alternating rows, and the default is the grid.
const layout = ref('grid');
onMounted(() => {
  layout.value = new URLSearchParams(location.search).get('layout') === 'rows' ? 'rows' : 'grid';
});

const features = [
  {
    title: 'Any model',
    text: 'Use an API key for Anthropic, OpenAI, OpenRouter, DeepSeek, and 9 more providers, sign in with ChatGPT or Grok, or point yuke at a local server.',
    link: '/docs/providers',
    linkText: 'Connect a model',
    scene: 'models',
    label: 'model',
  },
  {
    title: 'Sessions that keep',
    text: 'Every conversation is saved. Continue the newest one with yuke -c or open an older one by its ID. A bundled plugin summarizes old context, so long tasks keep going.',
    link: '/docs/get-started#continue-a-conversation',
    linkText: 'Continue a conversation',
    scene: 'sessions',
    label: 'sessions',
  },
  {
    title: 'Scripts and CI',
    text: 'Run one task without the UI and get JSON back, or drive yuke from another program over the JSONL protocol with yuke --rpc.',
    link: '/docs/get-started#run-one-task-without-the-ui',
    linkText: 'Run without the UI',
    scene: 'headless',
    label: 'sh',
  },
  {
    title: 'Your project, your rules',
    text: 'yuke reads AGENTS.md, lists your skills, and starts the local MCP servers of the project after you approve them.',
    link: '/docs/engine#prompt',
    linkText: 'Prompt and skills',
    code: `~/code/acme
├── AGENTS.md            instructions for the model
├── .agents/skills/      skills, read when they match
│   └── release/SKILL.md
└── .mcp.json            local MCP servers`,
  },
];
</script>

<template>
  <section class="features yuke-section" :class="layout" aria-labelledby="features-title">
    <h2 id="features-title" class="yuke-heading">A coding agent that stays out of your way.</h2>
    <p class="intro">One native binary for macOS and Linux. No plugin needed to start.</p>
    <div class="list">
      <article v-for="feature in features" :key="feature.title" class="feature">
        <div class="copy">
          <h3>{{ feature.title }}</h3>
          <p>{{ feature.text }}</p>
          <a :href="withBase(feature.link)">{{ feature.linkText }} <span aria-hidden="true">→</span></a>
        </div>
        <div class="visual">
          <Terminal v-if="feature.scene" :scene="scene(feature.scene)" :label="feature.label" trim />
          <pre v-else class="tree">{{ feature.code }}</pre>
        </div>
      </article>
    </div>
  </section>
</template>

<style scoped>
.features {
  margin-top: 120px;
}

h2 {
  max-width: 720px;
  margin: 0 auto;
  font-size: clamp(32px, 4.4vw, 52px);
  text-align: center;
  text-wrap: balance;
}

.intro {
  margin: 16px auto 0;
  color: var(--vp-c-text-2);
  font-size: 18px;
  text-align: center;
}

.list {
  margin-top: 56px;
}

h3 {
  margin: 0;
  color: var(--vp-c-text-1);
  font-size: 20px;
  font-weight: 650;
  letter-spacing: -0.02em;
}

.copy p {
  margin: 10px 0 0;
  color: var(--vp-c-text-2);
  font-size: 16px;
  line-height: 1.65;
}

.copy a {
  display: inline-block;
  margin-top: 12px;
  color: var(--vp-c-brand-1);
  font-size: 14px;
  font-weight: 500;
  text-decoration: none;
}

.copy a:hover {
  text-decoration: underline;
  text-underline-offset: 4px;
}

.tree {
  margin: 0;
  padding: 20px 22px;
  overflow-x: auto;
  border: 1px solid #262a26;
  border-radius: 10px;
  background: #0c0d0c;
  color: #f4f2eb;
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
  line-height: 1.7;
}

/* The grid: cards with the text above the picture. */
.grid .list {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 24px;
}

.grid .feature {
  display: flex;
  flex-direction: column;
  gap: 24px;
  padding: 28px;
  border: 1px solid var(--yuke-line);
  border-radius: 14px;
  background: var(--vp-c-bg-soft);
}

.grid .visual {
  margin-top: auto;
}

/* The rows: text and picture side by side, with the sides switching on each row. */
.rows .list {
  display: grid;
  gap: 96px;
  max-width: 1080px;
  margin-right: auto;
  margin-left: auto;
}

.rows .feature {
  display: grid;
  grid-template-columns: minmax(0, 5fr) minmax(0, 7fr);
  gap: 56px;
  align-items: center;
}

.rows .feature:nth-child(even) {
  grid-template-columns: minmax(0, 7fr) minmax(0, 5fr);
}

.rows .feature:nth-child(even) .copy {
  order: 2;
}

@media (max-width: 860px) {
  .grid .list,
  .rows .feature {
    grid-template-columns: minmax(0, 1fr);
  }

  .rows .feature:nth-child(even) .copy {
    order: 0;
  }

  .rows .list {
    gap: 64px;
  }
}
</style>
