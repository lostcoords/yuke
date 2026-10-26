import { defineConfig } from 'vitepress';
import { copyFileSync, cpSync, mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { groups, moved, slugs } from './pages.js';
import { repository, site } from './theme/project.js';

const project = fileURLToPath(new URL('..', import.meta.url));
const root = resolve(project, '..');
const publicDir = join(project, 'public');
const base = process.env.DOCS_BASE ?? '/';

// A static redirect, because GitHub Pages cannot send a 301 for a path.
const redirect = (target) => `<!doctype html>
<meta charset="utf-8">
<title>Moved</title>
<link rel="canonical" href="${site}${target}">
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0; url=${target}">
<p>This page moved to <a href="${target}">${site}${target}</a>.</p>
`;

export default defineConfig({
  // The pages are the Markdown in docs/; this folder holds only the theme and the static files.
  srcDir: '../docs',
  // The guides live in docs/guide/ and are served under /docs/.
  rewrites: Object.fromEntries(slugs.map((slug) => [`guide/${slug}.md`, `docs/${slug}.md`])),
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
    ['link', { rel: 'apple-touch-icon', href: `${base}apple-touch-icon.png` }],
    ['meta', { name: 'theme-color', content: '#0c0d0c' }],
  ],
  transformHead({ pageData, title, description }) {
    if (pageData.isNotFound) return [['meta', { name: 'robots', content: 'noindex' }]];
    const path = pageData.relativePath.replace(/(^|\/)index\.md$/, '$1').replace(/\.md$/, '');
    const url = `${site}${base}${path}`;
    const image = `${site}${base}og.png`;
    return [
      ['link', { rel: 'canonical', href: url }],
      ['meta', { property: 'og:type', content: path ? 'article' : 'website' }],
      ['meta', { property: 'og:site_name', content: 'yuke' }],
      ['meta', { property: 'og:url', content: url }],
      ['meta', { property: 'og:title', content: title }],
      ['meta', { property: 'og:description', content: description }],
      ['meta', { property: 'og:image', content: image }],
      ['meta', { property: 'og:image:width', content: '1200' }],
      ['meta', { property: 'og:image:height', content: '630' }],
      ['meta', { property: 'og:image:alt', content: 'yuke: Unleash your harness' }],
      ['meta', { name: 'twitter:card', content: 'summary_large_image' }],
      ['meta', { name: 'twitter:image', content: image }],
    ];
  },
  buildEnd({ outDir }) {
    // VitePress copies only srcDir/public, so the build copies this folder's public/ itself.
    cpSync(publicDir, outDir, { recursive: true });
    // The page serves the release installer, so `curl … /install.sh | bash` gets the tested
    // script. /install keeps the command that yuke-cloud printed working.
    copyFileSync(join(root, 'tools/install.sh'), join(outDir, 'install.sh'));
    copyFileSync(join(root, 'tools/install.sh'), join(outDir, 'install'));
    // The guides link their examples as plain files.
    cpSync(join(root, 'docs/guide/examples'), join(outDir, 'docs/examples'), { recursive: true });
    for (const [from, to] of Object.entries(moved)) {
      mkdirSync(join(outDir, from), { recursive: true });
      writeFileSync(join(outDir, from, 'index.html'), redirect(to));
    }
  },
  markdown: {
    html: false,
    attrs: { disable: true },
    // The guides link headings by their GitHub anchors: "## config.json" is #configjson.
    anchor: { slugify: (text) => text.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-') },
  },
  themeConfig: {
    logo: { light: '/logo-light.svg', dark: '/logo-dark.svg', alt: 'yuke' },
    siteTitle: 'yuke',
    nav: [
      { text: 'Docs', link: '/docs/', activeMatch: '^/docs/(?!benchmarks)' },
      { text: 'Benchmarks', link: '/docs/benchmarks' },
      { text: 'Install', link: '/docs/get-started' },
    ],
    sidebar: {
      '/docs/': groups.map(({ text, pages }) => ({
        text,
        items: pages.map(([slug, title]) => ({ text: title, link: `/docs/${slug}` })),
      })),
    },
    outline: [2, 3],
    search: { provider: 'local' },
    socialLinks: [{ icon: 'github', link: repository }],
    editLink: { pattern: `${repository}/edit/site/docs/:path`, text: 'Edit this page on GitHub' },
  },
});
