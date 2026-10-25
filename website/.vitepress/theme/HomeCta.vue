<script setup>
import { onBeforeUnmount, onMounted, ref } from 'vue';
import { withBase } from 'vitepress';
import InstallCommand from './InstallCommand.vue';
import { repository } from './project.js';

// The closing call to action above the footer: the install command and the mascot.
const root = ref(null);
const shown = ref(true);
let observer;

onMounted(() => {
  if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  shown.value = false;
  observer = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting) return;
    shown.value = true;
    observer.disconnect();
  }, { threshold: 0.35 });
  observer.observe(root.value);
});

onBeforeUnmount(() => {
  observer?.disconnect();
});
</script>

<template>
  <section ref="root" class="cta" :class="{ shown }">
    <div class="inner">
      <div class="pitch">
        <p class="yuke-label">Small tools, big possibilities</p>
        <h2 class="yuke-heading">Unleash your harness.</h2>
        <p class="lead">Install yuke, connect a model, and shape the TUI to the way you work.</p>
        <InstallCommand class="install" />
        <a class="go" :href="repository">Star on GitHub</a>
      </div>
      <img class="mascot" :src="withBase('/logo-dark.svg')" alt="" width="220" height="220" aria-hidden="true" />
    </div>
  </section>
</template>

<style scoped>
/* A full-width yuke-black band that runs straight into the footer, in both themes. */
.cta {
  order: 1;
  margin-top: 96px;
  border-top: 1px solid var(--yuke-terminal-line);
  background: var(--yuke-black);
  color: var(--yuke-white);
  --vp-c-bg: var(--yuke-black);
  --vp-c-text-1: var(--yuke-white);
  --vp-c-text-3: var(--yuke-muted);
  --vp-c-brand-1: var(--yuke-green);
  --vp-c-brand-soft: rgba(168, 207, 160, 0.14);
  --yuke-line: var(--yuke-terminal-line);
}

.inner {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  gap: 40px;
  align-items: center;
  box-sizing: border-box;
  margin: 0 auto;
  padding: 72px 24px;
  max-width: 1280px;
}

@media (min-width: 768px) {
  .inner {
    padding: 88px 48px;
  }
}

@media (min-width: 960px) {
  .inner {
    grid-template-columns: minmax(0, 1fr) auto;
    gap: 64px;
  }
}

h2 {
  margin-top: 14px;
  color: var(--yuke-white);
  font-size: clamp(40px, 5.5vw, 64px);
}

.lead {
  margin: 18px 0 0;
  max-width: 520px;
  color: #b8bbb4;
  font-size: 18px;
  line-height: 1.55;
}

.install {
  margin-top: 28px;
  max-width: 560px;
}

.go {
  display: inline-block;
  margin-top: 20px;
  padding: 0 22px;
  border: 1px solid var(--yuke-green);
  border-radius: 6px;
  color: var(--yuke-green);
  font-family: var(--vp-font-family-mono);
  font-size: 14px;
  line-height: 42px;
  text-decoration: none;
  transition: background-color 0.2s ease, color 0.2s ease;
}

.go:hover {
  background: var(--yuke-green);
  color: var(--yuke-black);
}

.mascot {
  justify-self: center;
  width: 220px;
  height: 220px;
  transform-origin: 50% 85%;
}

.shown .mascot {
  animation: hop 0.6s cubic-bezier(0.34, 1.56, 0.64, 1) both, sway 4s ease-in-out 0.8s infinite;
}

@keyframes hop {
  from { opacity: 0; transform: translateY(16px); }
  to { opacity: 1; transform: none; }
}

@keyframes sway {
  0%, 70%, 100% { rotate: 0deg; }
  78% { rotate: -6deg; }
  88% { rotate: 5deg; }
}
</style>
