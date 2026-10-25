<script setup>
import { useData } from 'vitepress';
import InstallCommand from './InstallCommand.vue';

const { frontmatter } = useData();
</script>

<template>
  <h1 class="heading">Unleash your <span class="harness">harness</span></h1>
  <p class="tagline">{{ frontmatter.hero.tagline }}</p>
  <InstallCommand class="install" />
</template>

<style scoped>
.heading {
  margin: 0 auto;
  max-width: 1100px;
  color: var(--vp-c-text-1);
  font-size: clamp(40px, 7vw, 84px);
  font-weight: 800;
  line-height: 1.08;
  letter-spacing: -0.025em;
  text-wrap: balance;
}

/* The motto's last word carries the brand gradient, and a leash-like stroke snaps loose under it. */
.harness {
  position: relative;
  display: inline-block;
  background: var(--yuke-hero);
  -webkit-background-clip: text;
  background-clip: text;
  color: transparent;
}

.harness::after {
  content: '';
  position: absolute;
  left: 4%;
  right: 4%;
  bottom: -0.04em;
  height: 0.07em;
  border-radius: 999px;
  background: var(--yuke-hero);
  transform-origin: left center;
  animation: unleash 1.1s cubic-bezier(0.34, 1.56, 0.64, 1) 0.4s both;
}

@keyframes unleash {
  0% { transform: scaleX(0); }
  60% { transform: scaleX(1.04); }
  100% { transform: scaleX(1); }
}

.install {
  margin: 28px auto 0;
  max-width: 520px;
}

/* On phones the whole command fits on one line, clear of the copy button. */
@media (max-width: 480px) {
  .install :deep(code) {
    padding: 0 54px 0 12px;
    font-size: 10px;
    letter-spacing: -0.02em;
  }
}
</style>
