// Guides use docs/guide/<slug>.md from main.
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
    text: 'Run headless',
    pages: [
      ['one-shot', 'One-shot tasks'],
      ['rpc', 'Embed with RPC'],
    ],
  },
  {
    text: 'Extend',
    pages: [
      ['first-plugin', 'Your first plugin'],
      ['plugins', 'Plugins'],
      ['ui', 'UI'],
      ['tools', 'Tools'],
      ['engine', 'Engine'],
    ],
  },
];

export const slugs = ['index', ...groups.flatMap(({ pages }) => pages.map(([slug]) => slug))];

// Old public links still lead to the relevant guide.
export const moved = {
  'docs/configuration': '/docs/config',
  'docs/configuration/modules': '/docs/plugins',
  'docs/configuration/plugins': '/docs/plugins',
  'docs/customize': '/docs/plugins',
  'docs/profile': '/docs/config',
  'docs/protocol': '/docs/rpc',
  'docs/types': '/docs/plugins',
};
