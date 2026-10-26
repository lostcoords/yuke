<script setup>
import { useData, withBase } from 'vitepress';
import { plugins, repository } from './project.js';

const { frontmatter } = useData();

const columns = [
  { title: 'Start', links: [
    { text: 'Get started', href: withBase('/docs/get-started') },
    { text: 'Your first plugin', href: withBase('/docs/first-plugin') },
    { text: 'Providers', href: withBase('/docs/providers') },
    { text: 'Benchmarks', href: withBase('/docs/benchmarks') },
  ] },
  { title: 'Plugins', links: [
    { text: 'Customize yuke', href: withBase('/docs/customize') },
    { text: 'Plugin collection', href: plugins },
    { text: 'Vim mode', href: `${plugins}/tree/main/plugins/vim-mode` },
  ] },
  { title: 'Project', links: [
    { text: 'GitHub', href: repository },
    { text: 'Releases', href: `${repository}/releases` },
    { text: 'Status', href: 'https://status.yuke.sh' },
  ] },
];
</script>

<template>
  <footer v-if="frontmatter.layout === 'home'" class="footer">
    <div class="inner">
      <nav v-for="column in columns" :key="column.title" class="column" :aria-label="column.title">
        <h3>{{ column.title }}</h3>
        <a v-for="link in column.links" :key="link.text" :href="link.href">{{ link.text }}</a>
      </nav>
    </div>
    <div class="bottom">
      <p>© 2026 LOST COORDS</p>
    </div>
  </footer>
</template>

<style scoped>
/* It continues the black band above it. */
.footer {
  border-top: 1px solid var(--yuke-terminal-line);
  background: var(--yuke-black);
  color: #b8bbb4;
  --vp-c-text-1: var(--yuke-white);
  --vp-c-text-2: #b8bbb4;
  --vp-c-text-3: var(--yuke-muted);
  --vp-c-divider: var(--yuke-terminal-line);
  --vp-c-brand-1: var(--yuke-green);
  font-size: 14px;
}

/* The columns and the copyright line share the page's content edges. */
.inner,
.bottom {
  box-sizing: border-box;
  margin: 0 auto;
  padding: 0 24px;
  max-width: 1280px;
}

@media (min-width: 640px) {
  .inner,
  .bottom {
    padding: 0 48px;
  }
}

@media (min-width: 960px) {
  .inner,
  .bottom {
    padding: 0 64px;
  }
}

.inner {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 32px;
  padding-top: 56px;
  padding-bottom: 40px;
}

@media (min-width: 640px) {
  .inner {
    grid-template-columns: repeat(3, minmax(0, 1fr));
  }
}

.column {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

h3 {
  margin: 0 0 4px;
  color: var(--vp-c-text-3);
  font-family: var(--vp-font-family-mono);
  font-size: 11px;
  font-weight: 500;
  letter-spacing: 0.18em;
  text-transform: uppercase;
}

.column a {
  color: var(--vp-c-text-2);
  text-decoration: none;
  transition: color 0.2s ease;
}

.column a:hover {
  color: var(--vp-c-brand-1);
}

.bottom p {
  margin: 0;
  font-family: var(--vp-font-family-mono);
  padding: 20px 0 32px;
  border-top: 1px solid var(--vp-c-divider);
  color: var(--vp-c-text-3);
  font-size: 13px;
}
</style>
