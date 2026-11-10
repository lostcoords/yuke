<script setup>
import { scene } from './frames.js';
import Terminal from './Terminal.vue';
</script>

<template>
  <section class="demo yuke-section" aria-label="yuke at work">
    <Terminal class="window" :scene="scene('task')" label="~/code/acme — yuke" play />
  </section>
</template>

<style scoped>
.demo {
  margin-top: 64px;
}

.window {
  max-width: 920px;
  margin: 0 auto;
}
</style>
