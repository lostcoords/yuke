<script setup>
import { useData, withBase } from 'vitepress';
import InstallCommand from './InstallCommand.vue';

const { frontmatter } = useData();
</script>

<template>
  <section class="hero yuke-section">
    <img class="mascot" :src="withBase('/mascot/coffee.png')" alt="" width="123" height="126" />
    <h1 class="yuke-heading">Unleash your <span>harness.</span></h1>
    <p class="lead">{{ frontmatter.tagline }}</p>
    <InstallCommand class="install" />
    <p class="links">
      <a :href="withBase('/docs/get-started')">Quick start <span aria-hidden="true">→</span></a>
      <a :href="withBase('/docs/plugins')">Plugins <span aria-hidden="true">→</span></a>
    </p>
  </section>
</template>

<style scoped>
.hero {
  padding-top: 64px;
  text-align: center;
}

.mascot {
  display: block;
  margin: 0 auto 24px;
}

h1 {
  font-size: clamp(44px, 7vw, 88px);
  text-wrap: balance;
}

h1 span {
  color: var(--vp-c-brand-1);
}

.lead {
  margin: 24px auto 0;
  max-width: 580px;
  color: var(--vp-c-text-2);
  font-size: 19px;
  line-height: 1.6;
  text-wrap: balance;
}

.install {
  margin: 32px auto 0;
  max-width: 520px;
  text-align: left;
}

.links {
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 24px;
  margin: 24px 0 0;
  font-size: 14px;
}

.links a {
  color: var(--vp-c-brand-1);
  font-weight: 500;
  text-decoration: none;
}

.links a:hover {
  text-decoration: underline;
  text-underline-offset: 4px;
}

@media (max-width: 639px) {
  .hero {
    padding-top: 40px;
  }
}
</style>
