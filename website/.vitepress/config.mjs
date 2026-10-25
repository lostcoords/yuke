import { defineConfig } from 'vitepress';
import { copyFileSync, cpSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { repository, site } from './theme/project.js';

const project = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(project, '..');
const publicDir = join(project, 'public');
const base = process.env.DOCS_BASE ?? '/';

export default defineConfig({
  // The pages are the Markdown in docs/; this folder holds only the theme and the static files.
  srcDir: '../docs',
  // Vite resolves a page's imports from docs/, which has no node_modules, so Vue comes from here.
  vite: { publicDir, resolve: { alias: { vue: join(project, 'node_modules/vue') } } },
  base,
  outDir: resolve(root, process.env.DOCS_OUTPUT ?? 'target/site'),
  cacheDir: resolve(root, 'target/site-cache'),
  cleanUrls: true,
  lang: 'en',
  // The brand is yuke black first; the switch still offers warm white.
  appearance: 'dark',
  title: 'yuke',
  description: 'A local, hackable harness for LLM agents.',
  sitemap: { hostname: site },
  head: [
    ['link', { rel: 'icon', href: `${base}logo.svg` }],
    ['meta', { name: 'theme-color', content: '#0c0d0c' }],
  ],
  transformHead({ pageData, title, description }) {
    const url = `${site}${base}${pageData.relativePath.replace(/index\.md$/, '')}`;
    return [
      ['link', { rel: 'canonical', href: url }],
      ['meta', { property: 'og:type', content: 'website' }],
      ['meta', { property: 'og:site_name', content: 'yuke' }],
      ['meta', { property: 'og:url', content: url }],
      ['meta', { property: 'og:title', content: title }],
      ['meta', { property: 'og:description', content: description }],
      ['meta', { name: 'twitter:card', content: 'summary' }],
    ];
  },
  // VitePress copies only srcDir/public, so the build copies this folder's public/ itself.
  // The page serves the release installer, so `curl … /install.sh | bash` gets the tested script.
  buildEnd({ outDir }) {
    cpSync(publicDir, outDir, { recursive: true });
    copyFileSync(join(root, 'tools/install.sh'), join(outDir, 'install.sh'));
  },
  markdown: {
    html: false,
    attrs: { disable: true },
  },
  themeConfig: {
    logo: { light: '/logo-light.svg', dark: '/logo-dark.svg', alt: 'yuke' },
    siteTitle: 'yuke',
    socialLinks: [{ icon: 'github', link: repository }],
  },
});
