<script setup>
import { scene } from './frames.js';
import Terminal from './Terminal.vue';
</script>

<template>
  <section class="demo yuke-section" aria-label="yuke at work">
    <Terminal class="window" :scene="scene('task')" label="~/code/yuke — yuke" play />
  </section>
</template>

<style scoped>
.demo {
  margin-top: 64px;
}

.window {
  max-width: 1040px;
  margin: 0 auto;
}
</style>
