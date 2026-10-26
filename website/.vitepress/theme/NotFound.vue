<script setup>
import { withBase } from 'vitepress';
import Mascot from './Mascot.vue';
</script>

<template>
  <section class="missing">
    <Mascot pose="thinking" class="mantis" />
    <p class="yuke-label">404</p>
    <h1 class="yuke-heading">Nothing here.</h1>
    <p class="lead">The mantis looked everywhere. This page does not exist, or it moved.</p>
    <p class="links">
      <a :href="withBase('/')">Home <span aria-hidden="true">→</span></a>
      <a :href="withBase('/docs/')">Documentation <span aria-hidden="true">→</span></a>
    </p>
  </section>
</template>

<style scoped>
.missing {
  padding: 96px 24px 128px;
  text-align: center;
}

.mantis {
  margin: 0 auto 28px;
  display: grid;
  width: 132px;
  transform-origin: 50% 85%;
  animation: look 3s ease-in-out infinite;
}

@keyframes look {
  0%, 100% { rotate: 0deg; }
  30% { rotate: -8deg; }
  60% { rotate: 8deg; }
}

h1 {
  margin-top: 12px;
  font-size: clamp(40px, 6vw, 64px);
}

.lead {
  margin: 18px auto 0;
  max-width: 420px;
  color: var(--vp-c-text-2);
  font-size: 17px;
  line-height: 1.6;
}

.links {
  display: flex;
  justify-content: center;
  gap: 28px;
  margin: 28px 0 0;
  font-size: 15px;
}

.links a {
  color: var(--vp-c-brand-1);
  font-weight: 600;
  text-decoration: none;
}

.links a:hover {
  text-decoration: underline;
  text-underline-offset: 4px;
}
</style>
