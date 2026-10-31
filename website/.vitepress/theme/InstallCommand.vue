<script setup>
import { onBeforeUnmount, ref } from 'vue';
import { site } from './project.js';

const command = `curl -fsSL ${site}/install.sh | bash`;
const copied = ref(false);
let timer;

async function copy() {
  await navigator.clipboard.writeText(command);
  copied.value = true;
  clearTimeout(timer);
  timer = setTimeout(() => { copied.value = false; }, 2000);
}

onBeforeUnmount(() => clearTimeout(timer));
</script>

<template>
  <div class="install">
    <code><span class="prompt" aria-hidden="true">$ </span>{{ command }}</code>
    <button type="button" class="copy" :class="{ copied }" :aria-label="copied ? 'Copied' : 'Copy the install command'" @click="copy">
      <svg v-if="!copied" viewBox="0 0 24 24" aria-hidden="true"><rect x="8" y="8" width="12" height="12" rx="2" /><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" /></svg>
      <svg v-else viewBox="0 0 24 24" aria-hidden="true"><path d="M5 12.5l4.5 4.5L19 7.5" /></svg>
    </button>
  </div>
</template>

<style scoped>
.install {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 0 8px 0 18px;
  height: 54px;
  border: 1px solid var(--yuke-line);
  border-radius: 6px;
  background: var(--vp-c-bg);
  transition: border-color 0.2s ease;
}

.install:hover {
  border-color: var(--yuke-green);
}

code {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  color: var(--vp-c-text-1);
  font-family: var(--vp-font-family-mono);
  font-size: 15px;
  white-space: nowrap;
  /* A narrow screen scrolls the command sideways, so every character stays readable. */
  overflow-x: auto;
  scrollbar-width: none;
}

.prompt {
  color: var(--vp-c-brand-1);
}

.copy {
  display: grid;
  flex: none;
  place-items: center;
  width: 38px;
  height: 38px;
  border-radius: 4px;
  color: var(--vp-c-text-3);
  transition: color 0.2s ease, background-color 0.2s ease;
}

.copy:hover,
.copy.copied {
  background: var(--vp-c-brand-soft);
  color: var(--vp-c-brand-1);
}

.copy svg {
  width: 18px;
  height: 18px;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}

@media (max-width: 480px) {
  .install {
    padding-left: 12px;
  }

  code {
    font-size: 11.5px;
  }
}
</style>
