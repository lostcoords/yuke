// The captured terminal frames. A missing scene is null, and its terminal shows a placeholder.
const files = import.meta.glob('./frames/*.json', { eager: true, import: 'default' });
const scenes = new Map();

export function scene(name) {
  const packed = files[`./frames/${name}.json`];
  if (!packed) return null;
  if (!scenes.has(name)) scenes.set(name, unpack(packed));
  return scenes.get(name);
}

// A packed scene has a table of styles, a run is [text, style] or "text" in style 0, and each frame lists only the
// rows that changed. An unchanged row keeps the array of the frame before.
function unpack(packed) {
  let lines = Array.from({ length: packed.rows }, () => []);
  const frames = packed.frames.map((frame) => {
    lines = lines.slice();
    for (const [row, runs] of Object.entries(frame.rows)) {
      lines[Number(row)] = runs.map((run) =>
        typeof run === 'string' ? { text: run } : { text: run[0], ...packed.styles[run[1]] },
      );
    }
    return { at: frame.at, lines };
  });
  return {
    cols: packed.cols,
    rows: packed.rows,
    background: packed.background,
    foreground: packed.foreground,
    frames,
  };
}
