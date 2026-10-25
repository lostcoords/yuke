<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';

// A stylized yuke session. Each step adds transcript rows and names the feature it shows.
// A line is a list of [class, text] runs.
const steps = [
  {
    feature: 'Your prompt',
    type: 'fix rounding in the checkout total',
    lines: [[['you', '› '], ['', 'fix rounding in the checkout total']]],
  },
  {
    feature: 'Model tools',
    lines: [
      [['tool', '● '], ['b', 'read '], ['', 'app/models/cart.rb']],
      [['dim', '  └ '], ['dim', '84 lines']],
      [['tool', '● '], ['b', 'edit '], ['', 'app/models/cart.rb'], ['ok', ' +3'], ['bad', ' -5']],
    ],
  },
  {
    feature: 'An engine hook from your plugin',
    lines: [
      [['bad', '✗ '], ['b', 'exec '], ['', 'git push --force']],
      [['dim', '  └ '], ['warn', 'blocked by guard: ask before a force push']],
    ],
  },
  {
    feature: 'Subagents',
    lines: [
      [['agent', '◆ '], ['b', 'reviewer '], ['dim', 'checks the diff']],
      [['dim', '  └ '], ['', '1 finding: round once, at the end']],
    ],
  },
  {
    feature: 'Questions that do not block the run',
    question: true,
    lines: [
      [['ask', '◇ '], ['b', 'queued '], ['', 'Keep the old total in the receipt API?']],
      [['dim', '  └ '], ['dim', 'the run continues with the rest']],
    ],
  },
  {
    feature: 'Model tools',
    lines: [
      [['tool', '● '], ['b', 'exec '], ['', 'bin/rails test']],
      [['dim', '  └ '], ['ok', '42 runs, 0 failures']],
      [['say', '  '], ['', 'Cart#total now rounds once, at the end.']],
    ],
  },
  {
    feature: 'Your own commands',
    type: '/hi',
    toast: 'hi from hello',
    lines: [],
  },
];

const lines = ref([]);
const typed = ref('');
const feature = ref('');
const toast = ref('');
const questions = ref(0);
const sent = ref(0);
const busy = ref(false);
const screen = ref(null);
let run = 0;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function finish() {
  lines.value = steps.flatMap((step) => step.lines);
  questions.value = 1;
  sent.value = 1;
  feature.value = 'Unleash your harness';
}

async function play(token) {
  while (token === run) {
    lines.value = [];
    questions.value = 0;
    sent.value = 0;
    for (const step of steps) {
      if (token !== run) return;
      feature.value = step.feature;
      if (step.type) {
        for (const char of step.type) {
          typed.value += char;
          await sleep(45);
          if (token !== run) return;
        }
        await sleep(350);
        typed.value = '';
        if (!step.toast) sent.value += 1;
      }
      busy.value = !step.toast;
      for (const line of step.lines) {
        await sleep(420);
        if (token !== run) return;
        lines.value = [...lines.value, line];
        screen.value?.scrollTo({ top: screen.value.scrollHeight, behavior: 'smooth' });
      }
      if (step.question) questions.value = 1;
      if (step.toast) {
        toast.value = step.toast;
        await sleep(2200);
        toast.value = '';
      }
      await sleep(900);
    }
    busy.value = false;
    await sleep(3500);
  }
}

onMounted(() => {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    finish();
    return;
  }
  run += 1;
  play(run);
});

onBeforeUnmount(() => {
  run += 1;
});
</script>

<template>
  <section class="demo yuke-section yuke-reveal" aria-label="A yuke session: a prompt, tool calls, a blocked command, a subagent, a queued question, and a plugin command">
    <header class="head">
      <div>
        <p class="yuke-label">The TUI</p>
        <h2 class="yuke-heading">Watch it work.</h2>
      </div>
      <p class="feature" aria-live="polite"><span class="dot"></span>{{ feature }}</p>
    </header>
    <div class="window">
      <div class="bar">
        <span class="lights"><i></i><i></i><i></i></span>
        <span class="title">~/shop — yuke</span>
      </div>
      <div ref="screen" class="screen" aria-hidden="true">
        <pre><code><span v-for="(line, i) in lines" :key="i" class="line"><span v-for="([kind, text], j) in line" :key="j" :class="kind">{{ text }}</span></span></code></pre>
      </div>
      <div class="composer" aria-hidden="true">
        <span class="you">› </span>{{ typed }}<span class="cursor"></span>
        <span v-if="toast" class="toast">{{ toast }}</span>
      </div>
      <div class="status" aria-hidden="true">
        <span class="mode"><span class="spin" :class="{ busy }"></span>opus · high</span>
        <span class="dim">main</span>
        <span class="right">
          <span v-if="questions" class="chip">? {{ questions }} question</span>
          <span v-if="sent" class="dim">sent {{ sent }} · plugin status</span>
        </span>
      </div>
    </div>
  </section>
</template>

<style scoped>
.demo {
  padding-top: 24px;
}

.head {
  display: flex;
  flex-wrap: wrap;
  align-items: flex-end;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 24px;
}

h2 {
  margin-top: 12px;
  font-size: clamp(36px, 5vw, 56px);
}

/* The terminal stays dark in both themes, like a real one. */
.window {
  overflow: hidden;
  border: 1px solid var(--yuke-terminal-line);
  border-radius: 8px;
  background: var(--yuke-terminal);
  color: #e4e6df;
  font-family: var(--vp-font-family-mono);
  font-size: 13.5px;
  text-align: left;
}

.bar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 11px 14px;
  border-bottom: 1px solid var(--yuke-terminal-line);
}

.lights {
  display: flex;
  gap: 7px;
}

.lights i {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: #3a3e39;
}

.title {
  flex: 1;
  margin-right: 46px;
  color: #858a84;
  font-size: 12px;
  text-align: center;
}

.screen {
  height: 320px;
  overflow: hidden;
  padding: 16px 18px 4px;
}

pre {
  margin: 0;
  white-space: pre-wrap;
}

.line {
  display: block;
  line-height: 1.75;
  animation: line-in 0.3s ease both;
}

@keyframes line-in {
  from { opacity: 0; transform: translateY(4px); }
}

.b { color: #f4f2eb; font-weight: 600; }
.dim { color: #858a84; }
.you { color: #a8cfa0; font-weight: 600; }
.tool { color: #a8cfa0; }
.ok { color: #a8cfa0; }
.bad { color: #ff6b6b; }
.warn { color: #f4c25b; }
.agent { color: #b48cff; }
.ask { color: #5ccdf2; }
.say { color: inherit; }

.composer {
  position: relative;
  margin: 8px 14px 10px;
  padding: 10px 12px;
  border: 1px solid var(--yuke-terminal-line);
  border-radius: 6px;
  min-height: 20px;
}

.cursor {
  display: inline-block;
  width: 8px;
  height: 16px;
  margin-left: 1px;
  vertical-align: -3px;
  background: #a8cfa0;
  animation: blink 1s steps(1) infinite;
}

@keyframes blink {
  50% { opacity: 0; }
}

.toast {
  position: absolute;
  right: 10px;
  top: 50%;
  padding: 3px 10px;
  border-radius: 999px;
  background: rgba(168, 207, 160, 0.16);
  color: #a8cfa0;
  font-size: 12px;
  transform: translateY(-50%);
  animation: line-in 0.3s ease both;
}

.status {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 7px 14px;
  border-top: 1px solid var(--yuke-terminal-line);
  font-size: 12px;
}

.mode {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  color: #a8cfa0;
}

.spin {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #3a3e39;
}

.spin.busy {
  background: #a8cfa0;
  animation: pulse 1s ease-in-out infinite;
}

@keyframes pulse {
  50% { opacity: 0.3; }
}

.right {
  display: inline-flex;
  gap: 12px;
  margin-left: auto;
}

.chip {
  padding: 0 8px;
  border-radius: 999px;
  background: #173444;
  color: #5ccdf2;
}

.feature {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0;
  color: var(--vp-c-text-2);
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
}

.feature .dot {
  width: 7px;
  height: 7px;
  border-radius: 50%;
  background: var(--yuke-green);
}

@media (max-width: 640px) {
  .window {
    font-size: 11.5px;
  }

  .screen {
    height: 260px;
  }
}
</style>
