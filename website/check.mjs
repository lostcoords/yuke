// Build the site, then check what a visitor and a link preview rely on: every internal link
// and anchor resolves, each page has one heading and its own metadata, the installer and the
// examples match their sources, and the old yuke.sh paths still lead somewhere.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { moved, slugs } from './.vitepress/pages.js';
import { site } from './.vitepress/theme/project.js';

const root = resolve(import.meta.dirname, '..');
const output = join(root, 'target/site');
execFileSync(join(import.meta.dirname, 'node_modules/.bin/vitepress'), ['build'], {
  cwd: import.meta.dirname,
  stdio: 'inherit',
  env: { ...process.env, DOCS_BASE: '/', DOCS_OUTPUT: output },
});

const files = (directory) =>
  readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? files(path) : [path];
  });

// The file that GitHub Pages serves for a path, with clean URLs and directory indexes.
function served(path) {
  const clean = decodeURIComponent(path).replace(/^\//, '');
  for (const candidate of [clean, `${clean}.html`, join(clean, 'index.html')]) {
    const file = join(output, candidate);
    if (existsSync(file) && statSync(file).isFile()) return file;
  }
  return null;
}

const ids = (file) => new Set([...readFileSync(file, 'utf8').matchAll(/ id="([^"]+)"/g)].map((match) => match[1]));
const pages = files(output).filter((file) => file.endsWith('.html') && !file.endsWith('404.html'));

let links = 0;
for (const file of pages) {
  const html = readFileSync(file, 'utf8');
  const name = relative(output, file);
  if (/http-equiv="refresh"/.test(html)) continue;
  assert.equal(html.match(/<h1[\s>]/g)?.length, 1, `${name} has one page heading`);
  assert.match(html, /<link rel="canonical" href="https:\/\/yuke\.sh\//, `${name} has a canonical URL`);
  assert.match(html, /<meta property="og:image" content="https:\/\/yuke\.sh\/og\.png"/, `${name} has a social card`);
  // The URL a browser shows for this file, so relative links resolve as they do there.
  const page = new URL(`/${name.replace(/(^|\/)index\.html$/, '$1').replace(/\.html$/, '')}`, site);
  for (const [, href] of html.matchAll(/href="([^"]*)"/g)) {
    const target = new URL(href.replaceAll('&amp;', '&'), page);
    if (target.origin !== page.origin || href.startsWith('https://')) continue;
    const resolved = served(target.pathname);
    assert.ok(resolved, `${name} links to ${href}, which exists`);
    const anchor = decodeURIComponent(target.hash.slice(1));
    if (anchor && resolved.endsWith('.html')) {
      assert.ok(ids(resolved).has(anchor), `${name} links to the anchor ${href}`);
    }
    links += 1;
  }
}

for (const slug of slugs) {
  const path = slug === 'index' ? '/docs/' : `/docs/${slug}`;
  assert.ok(served(path), `the guide ${slug} is published at ${path}`);
}
assert.ok(served('/docs/get-started'), 'the web client link to /docs/get-started works');

for (const [from, to] of Object.entries(moved)) {
  const html = readFileSync(served(`/${from}/`), 'utf8');
  assert.ok(html.includes(`url=${to}"`), `/${from} redirects to ${to}`);
  const [path, anchor] = to.split('#');
  assert.ok(served(path), `the redirect target ${to} exists`);
  if (anchor) assert.ok(ids(served(path)).has(anchor), `the redirect target ${to} has its anchor`);
}

const installer = readFileSync(join(root, 'tools/install.sh'));
assert.deepEqual(readFileSync(join(output, 'install.sh')), installer, '/install.sh is tools/install.sh');
assert.deepEqual(readFileSync(join(output, 'install')), installer, '/install is tools/install.sh');
for (const name of readdirSync(join(root, 'docs/guide/examples'))) {
  assert.deepEqual(
    readFileSync(join(output, 'docs/examples', name)),
    readFileSync(join(root, 'docs/guide/examples', name)),
    `the example ${name} is published`,
  );
}

const png = readFileSync(join(output, 'og.png'));
assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [1200, 630], 'the social card is 1200x630');
const icon = readFileSync(join(output, 'apple-touch-icon.png'));
assert.deepEqual([icon.readUInt32BE(16), icon.readUInt32BE(20)], [180, 180], 'the home-screen icon is 180x180');
assert.equal(readFileSync(join(output, 'CNAME'), 'utf8').trim(), new URL(site).host, 'CNAME names the site domain');
assert.ok(readFileSync(join(output, 'sitemap.xml'), 'utf8').includes(`<loc>${site}/docs/get-started</loc>`), 'the sitemap lists the guides');

console.log(`site check passed: ${pages.length} pages, ${links} internal links, ${Object.keys(moved).length} redirects`);
