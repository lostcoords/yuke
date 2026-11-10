<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';

const props = defineProps({
  scene: { type: Object, default: null },
  label: { type: String, default: '' },
  play: { type: Boolean, default: false },
  // The part of the screen to show, in cells: { top, rows, left, cols }. The default is the whole screen.
  crop: { type: Object, default: null },
});

// The server render shows the last frame, so the page reads well without JavaScript.
const index = ref(props.scene ? props.scene.frames.length - 1 : 0);
const frame = computed(() => props.scene?.frames[index.value]);
const area = computed(() => ({
  top: props.crop?.top ?? 0,
  rows: props.crop?.rows ?? props.scene?.rows ?? 0,
  left: props.crop?.left ?? 0,
  cols: props.crop?.cols ?? props.scene?.cols ?? 0,
}));

// Keep the cells of each row from `left` to `left + cols`. A run has one character per cell.
function cut(line) {
  const out = [];
  let column = 0;
  const end = area.value.left + area.value.cols;
  for (const run of line) {
    const from = Math.max(area.value.left - column, 0);
    const to = Math.min(end - column, run.text.length);
    if (to > from) out.push({ ...run, text: run.text.slice(from, to) });
    column += run.text.length;
  }
  return out;
}

const lines = computed(() => {
  const all = frame.value?.lines ?? [];
  return all.slice(area.value.top, area.value.top + area.value.rows).map(cut);
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
  // A terminal draws faint text in a color between the text and its background. The background stays.
  const color = run.dim ? `color-mix(in srgb, ${fg} 60%, ${bg ?? props.scene.background})` : fg;
  const style = { color };
  if (bg) style.background = bg;
  if (run.bold) style.fontWeight = 600;
  if (run.italic) style.fontStyle = 'italic';
  const lines = [run.underline && 'underline', run.strike && 'line-through'].filter(Boolean);
  if (lines.length) style.textDecoration = lines.join(' ');
  return style;
}

// idle: not started. playing, paused, done: the states of the animation.
const state = ref('idle');
const last = computed(() => props.scene?.frames.at(-1).at || 1);
const progress = computed(() => (state.value === 'idle' ? 0 : (frame.value?.at ?? 0) / last.value));

function step() {
  const frames = props.scene.frames;
  if (index.value >= frames.length - 1) {
    state.value = 'done';
    return;
  }
  const wait = frames[index.value + 1].at - frames[index.value].at;
  timer = setTimeout(() => {
    index.value += 1;
    step();
  }, wait);
}

function start() {
  clearTimeout(timer);
  index.value = 0;
  state.value = 'playing';
  step();
}

function toggle() {
  if (state.value === 'playing') {
    clearTimeout(timer);
    state.value = 'paused';
  } else if (state.value === 'paused') {
    state.value = 'playing';
    step();
  } else {
    start();
  }
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
      <button
        v-if="play && scene && scene.frames.length > 1"
        type="button"
        class="control"
        :class="state"
        @click="toggle"
      >{{ { idle: '▶ Play', playing: '❚❚ Pause', paused: '▶ Resume', done: '↻ Replay' }[state] }}</button>
    </div>
    <div v-if="play && scene && scene.frames.length > 1" class="progress" aria-hidden="true">
      <span :style="{ width: `${progress * 100}%` }" />
    </div>
    <div class="viewport">
      <pre
        v-if="frame"
        class="screen"
        :style="{ '--cols': area.cols, background: scene.background, color: scene.foreground }"
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

.control {
  padding: 2px 10px;
  border-radius: 999px;
  color: #858a84;
  font-family: var(--vp-font-family-mono);
  font-size: 12px;
  transition: color 0.2s ease, background-color 0.2s ease;
}

.control:hover {
  color: #a8cfa0;
}

/* At the end, the replay button takes the eye from the last frame. */
.control.done {
  background: #a8cfa0;
  color: #0c0d0c;
  font-weight: 600;
  animation: arrive 0.4s ease-out;
}

@keyframes arrive {
  from {
    opacity: 0;
    transform: translateY(-3px);
  }
}

.progress {
  height: 2px;
  background: #1a1d1a;
}

.progress span {
  display: block;
  height: 100%;
  background: #a8cfa0;
  transition: width 0.25s linear;
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

/* A run fills the height of its row. An inline background covers only the height of the font, which leaves a gap. */
.line > span {
  display: inline-block;
  height: 100%;
  vertical-align: top;
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
