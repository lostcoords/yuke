<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';

const props = defineProps({
  scene: { type: Object, default: null },
  label: { type: String, default: '' },
  play: { type: Boolean, default: false },
  // Drop the empty rows above the first row with content, for a still whose content sits at the bottom.
  trim: { type: Boolean, default: false },
});

// The server render shows the last frame, so the page reads well without JavaScript.
const index = ref(props.scene ? props.scene.frames.length - 1 : 0);
const frame = computed(() => props.scene?.frames[index.value]);
const lines = computed(() => {
  const all = frame.value?.lines ?? [];
  if (!props.trim) return all;
  const first = all.findIndex((line) => line.some((run) => run.bg || run.text.trim()));
  return first > 0 ? all.slice(first) : all;
});
const root = ref(null);
let timer;
let observer;

function runStyle(run) {
  let fg = run.fg ?? props.scene.foreground;
  let bg = run.bg;
  if (run.inverse) {
    [fg, bg] = [bg ?? props.scene.background, fg];
  }
  const style = { color: fg };
  if (bg) style.background = bg;
  if (run.bold) style.fontWeight = 600;
  if (run.italic) style.fontStyle = 'italic';
  if (run.dim) style.opacity = 0.6;
  const lines = [run.underline && 'underline', run.strike && 'line-through'].filter(Boolean);
  if (lines.length) style.textDecoration = lines.join(' ');
  return style;
}

function start() {
  clearTimeout(timer);
  const frames = props.scene.frames;
  index.value = 0;
  const next = () => {
    if (index.value >= frames.length - 1) return;
    const wait = frames[index.value + 1].at - frames[index.value].at;
    timer = setTimeout(() => {
      index.value += 1;
      next();
    }, wait);
  };
  next();
}

onMounted(() => {
  if (!props.play || !props.scene || props.scene.frames.length < 2) return;
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
  observer = new IntersectionObserver((entries) => {
    if (entries.some((entry) => entry.isIntersecting)) {
      observer.disconnect();
      start();
    }
  }, { threshold: 0.5 });
  observer.observe(root.value);
});

onBeforeUnmount(() => {
  clearTimeout(timer);
  observer?.disconnect();
});
</script>

<template>
  <figure ref="root" class="terminal">
    <div class="bar">
      <span class="dots" aria-hidden="true"><i /><i /><i /></span>
      <span class="label">{{ label }}</span>
      <button v-if="play && scene && scene.frames.length > 1" type="button" class="replay" @click="start">Replay</button>
    </div>
    <div class="viewport">
      <pre
        v-if="frame"
        class="screen"
        :style="{ '--cols': scene.cols, background: scene.background, color: scene.foreground }"
      ><span v-for="(line, row) in lines" :key="row" class="line"><span
        v-for="(run, column) in line"
        :key="column"
        :style="runStyle(run)"
      >{{ run.text }}</span></span></pre>
      <div v-else class="pending">frame pending</div>
    </div>
  </figure>
</template>

<style scoped>
.terminal {
  margin: 0;
  overflow: hidden;
  border: 1px solid #262a26;
  border-radius: 10px;
  background: #0c0d0c;
  box-shadow: 0 24px 60px -30px rgba(0, 0, 0, 0.45);
}

.bar {
  display: flex;
  align-items: center;
  gap: 12px;
  height: 34px;
  padding: 0 12px;
  border-bottom: 1px solid #262a26;
  background: #111311;
  color: #858a84;
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
}

.dots {
  display: flex;
  gap: 6px;
}

.dots i {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: #262a26;
}

.label {
  flex: 1;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.replay {
  color: #858a84;
  font-size: 12px;
}

.replay:hover {
  color: #a8cfa0;
}

.viewport {
  container-type: inline-size;
  padding: 10px 12px 12px;
}

.screen {
  margin: 0;
  overflow: hidden;
  /* JetBrains Mono advances 0.6 em per cell, so this fits the columns to the width. */
  font-family: var(--vp-font-family-mono);
  font-size: calc(100cqw / (var(--cols) * 0.6));
  line-height: 1.3;
  white-space: pre;
  /* A terminal draws each character alone, so "->" stays two cells. */
  font-variant-ligatures: none;
}

.line {
  display: block;
  height: 1.3em;
}

.pending {
  display: grid;
  place-items: center;
  aspect-ratio: 16 / 9;
  color: #858a84;
  font-family: var(--vp-font-family-mono);
  font-size: 13px;
}
</style>
