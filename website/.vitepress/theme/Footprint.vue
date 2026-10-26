<script setup>
import { withBase } from 'vitepress';
import Mascot from './Mascot.vue';
// From tools/bench-idle.py on 2026-10-26; docs/guide/benchmarks.md has the full table and the
// method. Each agent idled at its first screen; the values are medians of three runs.
const agents = [
  { name: 'yuke', memory: 12.5, self: true },
  { name: 'Claude Code', memory: 188.9 },
  { name: 'Codex', memory: 257.4 },
  { name: 'OpenCode', memory: 1231.5 },
];
const most = Math.max(...agents.map((agent) => agent.memory));

const stats = [
  { value: '12 MiB', label: 'memory at idle' },
  { value: '0.06 s', label: 'to the first screen' },
  { value: '16 MB', label: 'binary' },
  { value: '0', label: 'runtimes to install' },
];
</script>

<template>
  <section class="footprint yuke-section yuke-reveal">
    <Mascot pose="coffee" class="mascot" />
    <p class="yuke-label">Footprint</p>
    <h2 class="yuke-heading">Small by default.</h2>
    <p class="lead">yuke is one native binary. It needs no Node, no Python and no Electron, so it leaves your memory to the tests, the build and the other agents.</p>

    <dl class="stats">
      <div v-for="stat in stats" :key="stat.label" class="stat">
        <dt>{{ stat.label }}</dt>
        <dd>{{ stat.value }}</dd>
      </div>
    </dl>

    <figure class="chart">
      <figcaption class="yuke-label">Memory at idle, lower is better</figcaption>
      <div v-for="agent in agents" :key="agent.name" class="row" :class="{ self: agent.self }">
        <span class="name">{{ agent.name }}</span>
        <span class="track"><span class="bar" :style="{ width: `${(agent.memory / most) * 100}%` }"></span></span>
        <span class="value">{{ agent.memory >= 100 ? Math.round(agent.memory) : agent.memory }} MiB</span>
      </div>
      <p class="method">Idle at the first screen on an Apple M2 Pro, macOS 26.6. Median of three runs, October 2026. <a :href="withBase('/docs/benchmarks')">All results and the method →</a></p>
    </figure>
  </section>
</template>

<style scoped>
.footprint {
  margin-top: 128px;
  text-align: center;
}

.mascot {
  margin-bottom: 24px;
}

h2 {
  margin-top: 14px;
  font-size: clamp(40px, 6vw, 72px);
}

.lead {
  margin: 20px auto 0;
  max-width: 620px;
  color: var(--vp-c-text-2);
  font-size: 18px;
  line-height: 1.6;
  text-wrap: balance;
}

.stats {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 1px;
  margin: 48px 0 0;
  overflow: hidden;
  border: 1px solid var(--yuke-line);
  border-radius: 8px;
  background: var(--yuke-line);
}

@media (min-width: 768px) {
  .stats {
    grid-template-columns: repeat(4, minmax(0, 1fr));
  }
}

.stat {
  display: flex;
  flex-direction: column-reverse;
  gap: 6px;
  padding: 28px 16px;
  background: var(--vp-c-bg);
}

dd {
  margin: 0;
  color: var(--vp-c-text-1);
  font-size: clamp(32px, 4vw, 48px);
  font-weight: 800;
  letter-spacing: -0.04em;
  line-height: 1;
}

dt {
  color: var(--vp-c-text-3);
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.chart {
  margin: 24px 0 0;
  padding: 28px 24px 22px;
  border: 1px solid var(--yuke-line);
  border-radius: 8px;
  text-align: left;
}

figcaption {
  margin-bottom: 18px;
}

.row {
  display: grid;
  grid-template-columns: 110px minmax(0, 1fr) 80px;
  gap: 16px;
  align-items: center;
  padding: 7px 0;
  font-family: var(--vp-font-family-mono);
  font-size: 14px;
}

@media (min-width: 768px) {
  .row {
    grid-template-columns: 140px minmax(0, 1fr) 90px;
  }
}

.name {
  color: var(--vp-c-text-2);
}

.track {
  height: 12px;
  border-radius: 3px;
  background: var(--yuke-panel);
}

.bar {
  display: block;
  min-width: 4px;
  height: 100%;
  border-radius: 3px;
  background: var(--vp-c-text-3);
  opacity: 0.55;
}

.value {
  color: var(--vp-c-text-2);
  text-align: right;
}

.self .name,
.self .value {
  color: var(--vp-c-brand-1);
  font-weight: 600;
}

.self .bar {
  background: var(--yuke-green);
  opacity: 1;
}

.method {
  margin: 16px 0 0;
  color: var(--vp-c-text-3);
  font-size: 12.5px;
}

.method a {
  color: var(--vp-c-brand-1);
  text-decoration: none;
}
</style>
