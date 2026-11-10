// The captured terminal frames. A missing scene is null, and its terminal shows a placeholder.
const files = import.meta.glob('./frames/*.json', { eager: true, import: 'default' });

export function scene(name) {
  return files[`./frames/${name}.json`] ?? null;
}
