<script setup>
import { withBase } from 'vitepress';
</script>

<template>
  <section class="capabilities yuke-section" aria-labelledby="capabilities-title">
    <div class="content">
      <h2 id="capabilities-title">Your model. Your tools. Your workflow.</h2>
      <ul>
        <li>Change commands, keys, and views with <a :href="withBase('/docs/first-plugin')">plugins</a>.</li>
        <li>Add model tools and control the run with <a :href="withBase('/docs/tools')">tools</a> and <a :href="withBase('/docs/engine')">hooks</a>.</li>
        <li>Use a cloud provider or a local model server. <a :href="withBase('/docs/providers')">Connect a model →</a></li>
      </ul>
    </div>
  </section>
</template>

<style scoped>
.capabilities {
  margin-top: 72px;
  margin-bottom: 80px;
}

.content {
  max-width: 640px;
  margin: 0 auto;
  padding-top: 32px;
  border-top: 1px solid var(--yuke-line);
}

h2 {
  margin: 0;
  color: var(--vp-c-text-1);
  font-size: 20px;
  font-weight: 600;
  letter-spacing: -0.02em;
}

ul {
  display: grid;
  gap: 14px;
  margin: 22px 0 0;
  padding-left: 20px;
  color: var(--vp-c-text-2);
  font-size: 16px;
  line-height: 1.7;
}

a {
  color: var(--vp-c-brand-1);
  text-decoration: underline;
  text-underline-offset: 3px;
}
</style>
