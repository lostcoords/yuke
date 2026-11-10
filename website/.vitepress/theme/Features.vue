<script setup>
import { withBase } from 'vitepress';
import { repository } from './project.js';
import { scene } from './frames.js';
import Terminal from './Terminal.vue';

// Split a text into its plain, `code`, and **strong** parts.
const parts = (text) =>
  text
    .split(/(`[^`]+`|\*\*[^*]+\*\*)/)
    .filter(Boolean)
    .map((part) => {
      if (part.startsWith('`')) return { kind: 'code', text: part.slice(1, -1) };
      if (part.startsWith('**')) return { kind: 'strong', text: part.slice(2, -2) };
      return { kind: 'plain', text: part };
    });

// Every picture shows the same number of cells, so every picture has the same size.
const size = { cols: 60, rows: 12 };

// The benchmarks are not ready. Until then, an empty screen of the same size holds their place.
const empty = {
  cols: size.cols,
  rows: size.rows,
  background: '#0c0d0c',
  foreground: '#858a84',
  frames: [{ at: 0, lines: Array.from({ length: size.rows }, (_, row) => (row === 5 ? [{ text: '                    benchmarks (soon)' }] : [])) }],
};

// A drawn screen for pictures that are not yuke output, such as a CI view. Each row is a list of [text, color].
const drawn = (rows) => ({
  cols: size.cols,
  rows: size.rows,
  background: '#0c0d0c',
  foreground: '#f4f2eb',
  frames: [
    {
      at: 0,
      lines: Array.from({ length: size.rows }, (_, row) =>
        (rows[row] ?? []).map(([text, fg, bold]) => ({ text, fg, bold })),
      ),
    },
  ],
});

const job = (title, prompt) => [
  [[' ✓ ', '#a8cfa0'], [title, '#f4f2eb', true]],
  [[`   yuke -p "${prompt}" \\`, '#b8bbb4']],
  [['     --model "$MODEL" --reasoning default', '#858a84']],
  [],
];

// The jobs of a CI workflow that run yuke, in the way Cursor shows its CLI in GitHub Actions.
const ci = drawn([
  ...job('Review each pull request', 'Review this pull request.'),
  ...job('Explain a failed build', 'Read the test log and explain the failure.'),
  ...job('Update the changelog', 'Add this release to CHANGELOG.md.'),
]);

const features = [
  {
    title: 'Small and fast',
    text: "yuke is fast. Really fast. The TUI uses **12\u00a0MB** of memory and opens in **~20\u00a0ms**. And that's not all! You can extend and customize every part of it with **TypeScript plugins**.",
    link: '/docs/get-started',
    linkText: 'Quick start',
    visual: { scene: empty, label: 'benchmarks', top: 0 },
  },
  {
    title: 'Made to be hackable',
    text: 'yuke ships only the essentials and leaves the rest to you. Shape it around your workflow with **the same plugin system yuke is built on**.',
    link: '/docs/plugins',
    linkText: 'Plugins',
    extra: true,
    visual: { scene: scene('plugins'), label: '/plugins', top: 11 },
  },
  {
    title: 'Beyond the TUI',
    text: 'Run one-shot tasks with `-p` in a script or a CI job, or embed yuke in your own app over stdio with `--rpc`. **Your plugins work in every mode.**',
    link: '/docs/one-shot',
    linkText: 'Headless mode',
    visual: { scene: ci, label: '.github/workflows/yuke.yml', top: 0 },
  },
  {
    title: 'Bring your own model',
    text: 'Use an API key, sign in with your **ChatGPT or Grok subscription**, or run local models. yuke supports Anthropic, OpenAI, OpenRouter, DeepSeek, Mistral, and more.',
    link: '/docs/providers',
    linkText: 'Connect a model',
    visual: { scene: scene('models'), label: '/model', top: 12 },
  },
];
</script>

<template>
  <section class="yuke-section" aria-label="Features">
    <div class="features">
    <article v-for="feature in features" :key="feature.title" class="feature">
      <div class="copy">
        <h2>{{ feature.title }}</h2>
        <p>
          <template v-for="(part, index) in parts(feature.text)" :key="index"
            ><code v-if="part.kind === 'code'">{{ part.text }}</code><strong v-else-if="part.kind === 'strong'">{{
              part.text
            }}</strong><template v-else>{{ part.text }}</template></template
          >
        </p>
        <p v-if="feature.extra">
          Find plugins in the
          <a class="inline" :href="`${repository}-plugins`">official plugin repository</a>, and install them with
          <code>/plugins</code>.
        </p>
        <a class="more" :href="withBase(feature.link)">{{ feature.linkText }} <span aria-hidden="true">→</span></a>
      </div>
      <div class="visual">
        <Terminal
          :scene="feature.visual.scene"
          :label="feature.visual.label"
          :crop="{ top: feature.visual.top, rows: size.rows, left: 0, cols: size.cols }"
        />
      </div>
    </article>
    </div>
  </section>
</template>

<style scoped>
.features {
  display: grid;
  gap: 104px;
  max-width: 1040px;
  margin: 120px auto;
}

.feature {
  display: grid;
  grid-template-columns: minmax(0, 5fr) minmax(0, 7fr);
  gap: 56px;
  align-items: center;
}



h2 {
  margin: 0;
  padding: 0;
  border: 0;
  color: var(--vp-c-text-1);
  font-size: 28px;
  font-weight: 700;
  letter-spacing: -0.03em;
  line-height: 1.2;
}

p {
  margin: 12px 0 0;
  color: var(--vp-c-text-2);
  font-size: 16.5px;
  line-height: 1.65;
}

code {
  font-family: var(--vp-font-family-mono);
  font-size: 0.9em;
  white-space: nowrap;
}

/* The key facts of a text stand out in the color of a heading. */
strong {
  color: var(--vp-c-text-1);
  font-weight: 600;
}

.inline {
  color: var(--vp-c-brand-1);
  text-decoration: underline;
  text-underline-offset: 3px;
}

.more {
  display: inline-block;
  margin-top: 16px;
  color: var(--vp-c-brand-1);
  font-size: 14px;
  font-weight: 500;
  text-decoration: none;
}

.more:hover {
  text-decoration: underline;
  text-underline-offset: 4px;
}


@media (max-width: 860px) {
  .features {
    gap: 72px;
  }

  .feature {
    grid-template-columns: minmax(0, 1fr);
    gap: 24px;
  }
}
</style>
