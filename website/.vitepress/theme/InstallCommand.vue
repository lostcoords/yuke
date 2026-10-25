<script setup>
import { site } from './project.js';

// The install command as VitePress's code block markup, so its copy button works the same.
const install = [
  ['#6F42C1', '#B392F0', 'curl'],
  ['#005CC5', '#79B8FF', ' -fsSL'],
  ['#032F62', '#9ECBFF', ` ${site}/install.sh`],
  ['#D73A49', '#F97583', ' |'],
  ['#6F42C1', '#B392F0', ' bash'],
];
</script>

<template>
  <div class="vp-doc install">
    <div class="language-sh vp-adaptive-theme">
      <button title="Copy Code" class="copy"></button>
      <!-- Hidden like every label, but VitePress's copy button finds the code past it. -->
      <span class="lang">sh</span>
      <pre class="shiki shiki-themes github-light github-dark vp-code" tabindex="0"><code><span class="line"><span v-for="([light, dark, text], i) in install" :key="i" :style="{ '--shiki-light': light, '--shiki-dark': dark }">{{ text }}</span></span></code></pre>
    </div>
  </div>
</template>

<style scoped>
.install div[class*='language-'] {
  margin: 0;
  box-shadow: none;
  text-align: left;
}
</style>
