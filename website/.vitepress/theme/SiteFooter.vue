<script setup>
import { useData, withBase } from 'vitepress';
import { repository } from './project.js';

const { frontmatter } = useData();
</script>

<template>
  <footer v-if="frontmatter.layout === 'home'" class="footer yuke-section">
    <div class="content">
      <p>© 2026 LOST COORDS</p>
      <nav aria-label="Footer">
        <a :href="withBase('/docs/')">Docs</a>
        <a :href="repository" data-umami-event="github" data-umami-event-place="footer">GitHub</a>
        <a :href="`${repository}/releases`">Releases</a>
      </nav>
    </div>
  </footer>
</template>

<style scoped>
.content {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  padding: 24px 0;
  border-top: 1px solid var(--yuke-line);
  color: var(--vp-c-text-2);
  font-size: 13px;
}

p {
  margin: 0;
}

nav {
  display: flex;
  gap: 24px;
}

a {
  color: inherit;
  text-decoration: none;
}

a:hover {
  color: var(--vp-c-brand-1);
}
</style>
