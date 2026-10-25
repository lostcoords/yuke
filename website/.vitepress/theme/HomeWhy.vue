<script setup>
// The strengths of the TUI. Each card states one and shows the line of code or the screen
// detail that proves it.
const providers = ['Anthropic', 'OpenAI', 'OpenRouter', 'DeepSeek', 'Groq', 'xAI', 'Mistral', 'Together', 'Cerebras', 'Fireworks', 'MiniMax', 'OpenCode'];

const cards = [
  {
    title: 'Plugins all the way down',
    text: 'Commands, keys, status items, styles, dialogs and the transcript come from plugins. Replace a bundled part, such as the chat, with your own.',
    code: 'tui.keymap.add({ "ctrl+g": "example:hello" });',
  },
  {
    title: 'Hooks on every action',
    text: 'An engine hook sees each tool call before it runs. It can block, approve or replace the call, so your rules hold in every session.',
    code: 'ctx.hook("tool.before", (call) => …)',
  },
  {
    title: 'Your tools, your servers',
    text: 'Give the model a new tool in a few lines of JavaScript. Connect local or remote MCP servers, with OAuth when they need it.',
    code: 'ctx.tools.define({ name: "word_count", … })',
  },
  {
    title: 'Ask without stopping',
    text: 'The agent queues a question and keeps going with the work that does not depend on it. You answer when you are ready.',
    screen: [['ask', '◇ queued '], ['', 'Keep the old total?']],
  },
  {
    title: 'Subagents in parallel',
    text: 'Send a self-contained task to a child agent, or a reviewer. Each one reports back into your session when it finishes.',
    screen: [['agent', '◆ reviewer '], ['dim', '1 finding']],
  },
  {
    title: 'Sessions that last',
    text: 'Resume any saved conversation, fork it to try another path, and compact a long one to keep the context window clear.',
    code: 'yuke resume <id>',
  },
  {
    title: 'Shared project work',
    text: 'Tasks live with the project, not the chat. Every session and checkout sees the same list, and each task has one owner.',
    screen: [['ok', '● now '], ['', 'Landing page for yuke']],
  },
  {
    title: 'Reload, not restart',
    text: 'Run /reload after you change a plugin. Plugins load from a folder or a public GitHub repository, pinned to a commit.',
    code: '/reload',
  },
];
</script>

<template>
  <section class="why">
    <div class="inner">
      <h2>A harness that <em>bends to you</em></h2>
      <p class="lead">Most coding agents give you their workflow. yuke gives you the parts: change any surface of the TUI and any step of the run, in JavaScript with full types.</p>

      <div class="grid">
        <article v-for="card in cards" :key="card.title" class="card">
          <h3>{{ card.title }}</h3>
          <p>{{ card.text }}</p>
          <code v-if="card.code" class="snippet">{{ card.code }}</code>
          <code v-else class="snippet screen"><span v-for="([kind, text], i) in card.screen" :key="i" :class="kind">{{ text }}</span></code>
        </article>
      </div>
    </div>
  </section>

  <section class="models">
    <div class="inner">
      <h2>Bring <em>any model</em></h2>
      <p class="lead">Set a key, or log in with a ChatGPT or Grok account. Point <code>providers.json</code> at a local server, and switch models from the TUI.</p>
      <ul class="providers">
        <li v-for="name in providers" :key="name">{{ name }}</li>
        <li class="local">Your local server</li>
      </ul>
    </div>
  </section>
</template>

<style scoped>
.why,
.models {
  box-sizing: border-box;
  margin: 0 auto;
  padding: 96px 24px 0;
  width: 100%;
  max-width: 1280px;
}

@media (min-width: 640px) {
  .why,
  .models {
    padding-left: 48px;
    padding-right: 48px;
  }
}

@media (min-width: 960px) {
  .why,
  .models {
    padding-left: 64px;
    padding-right: 64px;
  }
}

h2 {
  margin: 0;
  color: var(--vp-c-text-1);
  font-size: 32px;
  font-weight: 800;
  line-height: 1.15;
  letter-spacing: -0.01em;
  text-align: center;
  text-wrap: balance;
}

@media (min-width: 960px) {
  h2 {
    font-size: 44px;
  }
}

h2 em {
  background: var(--yuke-hero);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
  font-style: normal;
}

.lead {
  margin: 16px auto 0;
  max-width: 680px;
  color: var(--vp-c-text-2);
  font-size: 18px;
  line-height: 1.55;
  text-align: center;
  text-wrap: balance;
}

.lead code {
  padding: 2px 6px;
  border-radius: 8px;
  background: var(--vp-code-bg);
  color: var(--vp-code-color);
  font-size: 0.85em;
}

.grid {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 16px;
  margin-top: 48px;
}

@media (min-width: 640px) {
  .grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}

@media (min-width: 1100px) {
  .grid {
    grid-template-columns: repeat(4, minmax(0, 1fr));
  }
}

.card {
  display: flex;
  flex-direction: column;
  padding: 22px;
  border: 1px solid var(--yuke-frame);
  border-radius: 20px;
  background: var(--vp-c-bg);
  box-shadow: var(--yuke-card);
  transition: border-color 0.2s ease, box-shadow 0.25s ease;
}

.card:hover {
  border-color: var(--yuke-green);
  box-shadow: var(--yuke-glow);
}

h3 {
  margin: 0;
  color: var(--vp-c-text-1);
  font-size: 18px;
  font-weight: 800;
  line-height: 1.3;
}

.card p {
  flex: 1;
  margin: 10px 0 18px;
  color: var(--vp-c-text-2);
  font-size: 15px;
  line-height: 1.6;
}

/* Snippets look like a line of the terminal: dark in both themes. */
.snippet {
  display: block;
  overflow: hidden;
  padding: 9px 12px;
  border-radius: 10px;
  background: #101412;
  color: #d9e4dc;
  font-family: var(--vp-font-family-mono);
  font-size: 12.5px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.dim { color: #6f7d73; }
.ok { color: #5fd68a; }
.agent { color: #b48cff; }
.ask { color: #5ccdf2; }

.providers {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 10px;
  margin: 36px auto 0;
  padding: 0;
  max-width: 860px;
  list-style: none;
}

.providers li {
  padding: 8px 16px;
  border: 1px solid var(--yuke-frame);
  border-radius: 999px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  font-size: 15px;
  font-weight: 700;
  box-shadow: var(--yuke-card);
}

.providers .local {
  border-style: dashed;
  border-color: var(--yuke-green);
  color: var(--vp-c-brand-1);
}
</style>
