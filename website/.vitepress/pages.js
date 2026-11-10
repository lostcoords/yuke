// Guides use docs/guide/<slug>.md. The theme guide stays at docs/themes.md with the source on main.
export const groups = [
  { text: 'Start here', pages: [['get-started', 'Quick start']] },
  {
    text: 'Configure',
    pages: [
      ['config', 'Configuration'],
      ['providers', 'Providers'],
      ['instructions', 'AGENTS.md and skills'],
      ['mcp', 'MCP servers'],
      ['themes', 'Themes'],
    ],
  },
  {
    text: 'Headless',
    pages: [
      ['one-shot', 'One-shot tasks'],
      ['rpc', 'Embed with RPC'],
    ],
  },
  {
    text: 'Extend',
    pages: [
      ['customize', 'Customize yuke'],
      ['first-plugin', 'Your first plugin'],
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
  'docs/configuration': '/docs/config',
  'docs/configuration/modules': '/docs/types',
  'docs/configuration/plugins': '/docs/plugins',
  'docs/profile': '/docs/config',
  'docs/protocol': '/docs/rpc',
};
