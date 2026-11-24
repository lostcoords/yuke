<script setup>
import { computed, onBeforeUnmount, onMounted, ref } from 'vue';

const props = defineProps({
  scene: { type: Object, default: null },
  label: { type: String, default: '' },
  play: { type: Boolean, default: false },
  // The part of the screen to show, in cells: { top, rows, left, cols }. The default is the whole screen.
  crop: { type: Object, default: null },
});

// An animation starts on its first frame, so its end does not show before it plays. A still shows its last frame.
const index = ref(props.play || !props.scene ? 0 : props.scene.frames.length - 1);
const frame = computed(() => props.scene?.frames[index.value]);
const area = computed(() => ({
  top: props.crop?.top ?? 0,
  rows: props.crop?.rows ?? props.scene?.rows ?? 0,
  left: props.crop?.left ?? 0,
  cols: props.crop?.cols ?? props.scene?.cols ?? 0,
}));

// Keep the cells of each row from `left` to `left + cols`. A run has one character per cell. A sextant is two UTF-16
// units, so the count uses code points.
function cut(line) {
  const out = [];
  let column = 0;
  const end = area.value.left + area.value.cols;
  for (const run of line) {
    const characters = Array.from(run.text);
    const from = Math.max(area.value.left - column, 0);
    const to = Math.min(end - column, characters.length);
    if (to > from) out.push({ ...run, text: characters.slice(from, to).join('') });
    column += characters.length;
  }
  return out;
}

// The quadrants of U+2596 to U+259F, as bits: 1 upper left, 2 upper right, 4 lower left, 8 lower right.
const QUADRANTS = [4, 8, 1, 13, 9, 7, 11, 2, 6, 14];

// The rects of a block element or a sextant in a cell of 1 × 1, as [x, y, width, height, opacity], or null for
// another character. A terminal draws these to the edges of the cell, so the cells of a picture join. A font draws
// them at its own size, and the site font has no sextants, so the browser takes them from a font with other metrics.
function blockRects(character) {
  const code = character.codePointAt(0);
  if (code >= 0x1fb00 && code <= 0x1fb3b) {
    // The 60 sextants are the 2 × 3 patterns 1 to 62 without the left half (21) and the right half (42).
    let bits = code - 0x1fb00 + 1;
    if (bits >= 21) bits += 1;
    if (bits >= 42) bits += 1;
    const rects = [];
    for (let cell = 0; cell < 6; cell += 1) {
      if (bits & (1 << cell)) rects.push([(cell % 2) / 2, Math.floor(cell / 2) / 3, 1 / 2, 1 / 3, 1]);
    }
    return rects;
  }
  if (code === 0x2580) return [[0, 0, 1, 1 / 2, 1]];
  if (code >= 0x2581 && code <= 0x2588) {
    const eighths = code - 0x2580;
    return [[0, 1 - eighths / 8, 1, eighths / 8, 1]];
  }
  if (code >= 0x2589 && code <= 0x258f) return [[0, 0, (0x2590 - code) / 8, 1, 1]];
  if (code === 0x2590) return [[1 / 2, 0, 1 / 2, 1, 1]];
  if (code >= 0x2591 && code <= 0x2593) return [[0, 0, 1, 1, (code - 0x2590) / 4]];
  if (code === 0x2594) return [[0, 0, 1, 1 / 8, 1]];
  if (code === 0x2595) return [[7 / 8, 0, 1 / 8, 1, 1]];
  if (code >= 0x2596 && code <= 0x259f) {
    const bits = QUADRANTS[code - 0x2596];
    const rects = [];
    for (let cell = 0; cell < 4; cell += 1) {
      if (bits & (1 << cell)) rects.push([(cell % 2) / 2, Math.floor(cell / 2) / 2, 1 / 2, 1 / 2, 1]);
    }
    return rects;
  }
  return null;
}

// How far a shape that meets an edge of its cell reaches past it, in cells. Two runs and two rows round their edges
// to pixels apart, which leaves a seam of one pixel between them at a screen scale such as 125%. The overlap hides it.
const BLEED_X = 0.06;
const BLEED_Y = 0.04;

// Split each run at its block characters. A stretch of them becomes one run with `rects` and its `width` in cells.
function split(line) {
  const out = [];
  for (const run of line) {
    let text = '';
    let blocks = null;
    for (const character of run.text) {
      const rects = blockRects(character);
      if (rects) {
        if (text) out.push({ ...run, text });
        text = '';
        blocks ??= { ...run, text: '', width: 0, rects: [] };
        for (const [x, y, width, height, opacity] of rects) {
          // An overlap of a shade would draw a darker line, so a shade keeps its edges.
          const bleed = opacity === 1;
          const left = bleed && x === 0 ? BLEED_X : 0;
          const right = bleed && x + width === 1 ? BLEED_X : 0;
          const top = bleed && y === 0 ? BLEED_Y : 0;
          const bottom = bleed && y + height === 1 ? BLEED_Y : 0;
          blocks.rects.push([
            blocks.width + x - left,
            y - top,
            width + left + right,
            height + top + bottom,
            opacity,
          ]);
        }
        blocks.width += 1;
      } else {
        if (blocks) out.push(blocks);
        blocks = null;
        text += character;
      }
    }
    if (text) out.push({ ...run, text });
    if (blocks) out.push(blocks);
  }
  return out;
}

const lines = computed(() => {
  const all = frame.value?.lines ?? [];
  return all.slice(area.value.top, area.value.top + area.value.rows).map((line) => split(cut(line)));
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
  // With reduced motion, the animation never plays, so it shows its end.
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
    index.value = props.scene.frames.length - 1;
    return;
  }
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
      ><svg
        v-if="run.rects"
        class="blocks"
        :viewBox="`0 0 ${run.width} 1`"
        preserveAspectRatio="none"
        :style="{ width: `${run.width * 0.6}em` }"
        aria-hidden="true"
      ><rect
        v-for="(rect, at) in run.rects"
        :key="at"
        :x="rect[0]"
        :y="rect[1]"
        :width="rect[2]"
        :height="rect[3]"
        :fill-opacity="rect[4]"
      /></svg><template v-else>{{ run.text }}</template></span></span></pre>
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

/* Block characters fill the whole cell, so the rows of a picture join. Crisp edges keep a seam out of a shared edge in
   one run. A shape at the edge of a cell reaches past the SVG box, so the box must not clip it. */
.blocks {
  display: block;
  height: 100%;
  overflow: visible;
  fill: currentColor;
  shape-rendering: crispEdges;
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
