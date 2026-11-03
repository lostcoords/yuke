<script setup>
import { withBase } from 'vitepress';
</script>

<template>
  <section class="capabilities yuke-section" aria-labelledby="capabilities-title">
    <div class="content">
      <h2 id="capabilities-title">Features</h2>
      <ul>
        <li>Run a native binary through the terminal UI or <a :href="withBase('/docs/profile#modes')">RPC</a>.</li>
        <li>Write <a :href="withBase('/docs/first-plugin')">TypeScript plugins</a> to add tools, hooks, and views.</li>
        <li>Use your API keys or a ChatGPT or Grok subscription. <a :href="withBase('/docs/providers')">Connect a model →</a></li>
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
