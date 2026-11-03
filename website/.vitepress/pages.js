// Guides use docs/guide/<slug>.md. The theme guide stays at docs/themes.md with the source on main.
export const groups = [
  { text: 'Start here', pages: [['get-started', 'Quick start'], ['first-plugin', 'Your first plugin']] },
  {
    text: 'Configure',
    pages: [
      ['profile', 'Profile'],
      ['providers', 'Providers'],
      ['themes', 'Themes'],
    ],
  },
  {
    text: 'Extend',
    pages: [
      ['customize', 'Customize yuke'],
      ['plugins', 'Plugins'],
      ['ui', 'UI'],
      ['tools', 'Tools'],
      ['engine', 'Engine'],
      ['types', 'Types'],
    ],
  },
];

export const slugs = ['index', ...groups.flatMap(({ pages }) => pages.map(([slug]) => slug))];

// Old public links still lead to the relevant guide.
export const moved = {
  'docs/configuration': '/docs/profile',
  'docs/configuration/modules': '/docs/profile',
  'docs/configuration/plugins': '/docs/plugins',
  'docs/protocol': '/docs/',
};
