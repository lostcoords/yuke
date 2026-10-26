<script setup>
import { withBase } from 'vitepress';

// A mascot pose from the brand sheet, on a warm white tile as the sheet shows it. The poses
// have black outlines, so the tile keeps them visible on the dark theme too.
defineProps({ pose: { type: String, required: true } });
</script>

<template>
  <span class="tile" aria-hidden="true">
    <img :src="withBase(`/mascot/${pose}.png`)" alt="" />
  </span>
</template>

<style scoped>
.tile {
  display: inline-grid;
  place-items: end center;
  width: 132px;
  height: 132px;
  padding-bottom: 6px;
  box-sizing: border-box;
  border: 1px solid var(--yuke-line);
  border-radius: 24px;
  background: var(--yuke-white);
}

img {
  max-width: 112px;
  max-height: 112px;
}
</style>
