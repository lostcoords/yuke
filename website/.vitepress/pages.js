// The documentation pages, in sidebar order. Each source is docs/guide/<slug>.md, and each
// page is served at /docs/<slug>.
export const groups = [
  { text: 'Start here', pages: [['get-started', 'Get started'], ['first-plugin', 'Your first plugin']] },
  {
    text: 'Customize',
    pages: [
      ['customize', 'Customize yuke'],
      ['profile', 'Profile'],
      ['providers', 'Providers'],
      ['plugins', 'Plugins'],
      ['ui', 'UI'],
      ['tools', 'Tools'],
      ['engine', 'Engine'],
      ['types', 'Types'],
    ],
  },
  { text: 'Reference', pages: [['benchmarks', 'Benchmarks']] },
];

export const slugs = ['index', ...groups.flatMap(({ pages }) => pages.map(([slug]) => slug))];

// Pages that yuke-cloud served at yuke.sh before this site. Each old path redirects to the
// page that replaced it, so old links and the web client keep working.
export const moved = {
  'docs/configuration': '/docs/profile',
  'docs/configuration/modules': '/docs/profile#modules',
  'docs/configuration/plugins': '/docs/plugins',
  'docs/protocol': '/docs/',
};
