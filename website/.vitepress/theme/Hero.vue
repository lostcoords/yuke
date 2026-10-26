<script setup>
import { useData, withBase } from 'vitepress';
import InstallCommand from './InstallCommand.vue';
import { repository } from './project.js';

const { frontmatter } = useData();
</script>

<template>
  <section class="hero yuke-section">
    <h1 class="yuke-heading">Unleash your <span class="harness">harness</span></h1>
    <p class="lead">{{ frontmatter.tagline }}</p>
    <InstallCommand class="install" />
    <p class="links">
      <a :href="repository">View on GitHub <span aria-hidden="true">→</span></a>
      <a :href="withBase('/docs/get-started')">Get started <span aria-hidden="true">→</span></a>
    </p>
  </section>
</template>

<style scoped>
.hero {
  padding-top: calc(var(--vp-nav-height) + 64px);
  text-align: center;
}

@media (min-width: 960px) {
  .hero {
    padding-top: calc(var(--vp-nav-height) + 88px);
  }
}

h1 {
  font-size: clamp(48px, 8vw, 104px);
  text-wrap: balance;
}

.harness {
  color: var(--vp-c-brand-1);
}

.lead {
  margin: 24px auto 0;
  max-width: 640px;
  color: var(--vp-c-text-2);
  font-size: 19px;
  line-height: 1.55;
  text-wrap: balance;
}

.install {
  margin: 36px auto 0;
  max-width: 520px;
  text-align: left;
}

.links {
  display: flex;
  justify-content: center;
  gap: 28px;
  margin: 18px 0 0;
  font-size: 14px;
}

.links a {
  color: var(--vp-c-text-2);
  font-weight: 500;
  text-decoration: none;
  transition: color 0.2s ease;
}

.links a:hover {
  color: var(--vp-c-brand-1);
}
</style>
