<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { useData, withBase } from 'vitepress';
import InstallCommand from './InstallCommand.vue';
import { repository } from './project.js';

const { frontmatter } = useData();

// The loop every run follows, typed one step at a time; the last step is yuke itself.
const steps = ['think', 'plan', 'code', 'run', 'yuke'];
const shown = ref(steps.length);
let timer;

onMounted(() => {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  shown.value = 0;
  timer = setInterval(() => {
    shown.value = shown.value > steps.length + 4 ? 0 : shown.value + 1;
  }, 520);
});

onBeforeUnmount(() => clearInterval(timer));
</script>

<template>
  <section class="hero yuke-section">
    <div class="pitch">
      <p class="yuke-label">{{ frontmatter.kicker }}</p>
      <h1 class="yuke-heading">Unleash your <span class="harness">harness.</span></h1>
      <p class="lead">{{ frontmatter.tagline }}</p>
      <InstallCommand class="install" />
      <p class="links">
        <a :href="repository">View on GitHub <span aria-hidden="true">→</span></a>
        <a :href="withBase('/#run-yuke')">Quick start <span aria-hidden="true">→</span></a>
      </p>
    </div>

    <div class="stage" aria-hidden="true">
      <img class="mantis yuke-light" :src="withBase('/logo-light.svg')" alt="" width="300" height="300" />
      <img class="mantis yuke-dark" :src="withBase('/logo-dark.svg')" alt="" width="300" height="300" />
      <ol class="loop">
        <li v-for="(step, i) in steps" :key="step" :class="{ on: i < shown, last: i === steps.length - 1 }">
          <span class="caret">&gt;</span> {{ step }}<span v-if="i === steps.length - 1" class="cursor"></span>
        </li>
      </ol>
      <p class="bubble">small tools,<br />big possibilities.</p>
      <p class="side yuke-label">Build<br />your own<br />agents.</p>
      <div class="ground"></div>
    </div>
  </section>
</template>

<style scoped>
.hero {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 48px;
  align-items: center;
  padding-top: calc(var(--vp-nav-height) + 48px);
  padding-bottom: 48px;
}

@media (min-width: 960px) {
  .hero {
    grid-template-columns: minmax(0, 1.05fr) minmax(0, 1fr);
    gap: 32px;
    padding-top: calc(var(--vp-nav-height) + 72px);
    padding-bottom: 72px;
  }
}

h1 {
  margin-top: 18px;
  font-size: clamp(48px, 7.4vw, 92px);
}

.harness {
  color: var(--vp-c-brand-1);
}

.lead {
  margin: 24px 0 0;
  max-width: 540px;
  color: var(--vp-c-text-2);
  font-size: 18px;
  line-height: 1.55;
}

.install {
  margin-top: 32px;
  max-width: 560px;
}

.links {
  display: flex;
  flex-wrap: wrap;
  gap: 28px;
  margin: 18px 0 0;
  font-size: 14px;
}

.links a {
  color: var(--vp-c-text-2);
  font-weight: 500;
  text-decoration: none;
  transition: color 0.2s ease;
}

.links a:hover {
  color: var(--vp-c-brand-1);
}

/* The mantis stands on a line, beside the loop it runs. */
.stage {
  position: relative;
  display: grid;
  grid-template-columns: auto auto;
  justify-content: center;
  align-items: end;
  gap: 8px 32px;
  padding-bottom: 28px;
  min-height: 300px;
}

.mantis {
  width: clamp(180px, 22vw, 300px);
  height: auto;
  transform-origin: 50% 85%;
  animation: sway 6s ease-in-out infinite;
}

@keyframes sway {
  0%, 80%, 100% { rotate: 0deg; }
  86% { rotate: -3deg; }
  93% { rotate: 2deg; }
}

.loop {
  margin: 0 0 24px;
  padding: 0;
  list-style: none;
  font-family: var(--vp-font-family-mono);
  font-size: clamp(16px, 1.6vw, 20px);
  line-height: 1.7;
}

.loop li {
  color: var(--vp-c-text-1);
  opacity: 0;
  transform: translateX(-6px);
  transition: opacity 0.25s ease, transform 0.25s ease;
}

.loop li.on {
  opacity: 1;
  transform: none;
}

.loop li.last {
  color: var(--vp-c-brand-1);
  font-weight: 600;
}

.caret {
  color: var(--vp-c-text-3);
}

.cursor {
  display: inline-block;
  width: 0.55em;
  height: 1.05em;
  margin-left: 6px;
  vertical-align: -0.15em;
  background: var(--yuke-green);
  animation: blink 1s steps(1) infinite;
}

@keyframes blink {
  50% { opacity: 0; }
}

.bubble {
  position: absolute;
  top: 0;
  right: 0;
  margin: 0;
  padding: 10px 14px;
  border: 1px solid var(--yuke-green);
  border-radius: 6px;
  background: var(--vp-c-bg);
  color: var(--vp-c-text-1);
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
  line-height: 1.5;
}

.bubble::after {
  content: '';
  position: absolute;
  left: 22px;
  bottom: -7px;
  width: 12px;
  height: 12px;
  border-right: 1px solid var(--yuke-green);
  border-bottom: 1px solid var(--yuke-green);
  background: var(--vp-c-bg);
  transform: rotate(45deg);
}

.side {
  position: absolute;
  right: 0;
  bottom: 44px;
  line-height: 1.8;
  text-align: right;
}

.ground {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 28px;
  height: 1px;
  background: var(--vp-c-text-3);
  opacity: 0.6;
}

@media (max-width: 959px) {
  .bubble,
  .side {
    display: none;
  }
}

@media (max-width: 480px) {
  .stage {
    grid-template-columns: auto;
  }

  .loop {
    display: none;
  }
}
</style>
