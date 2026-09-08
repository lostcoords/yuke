// yuke:layout — a small terminal-cell layout solver for retained views.

/** @typedef {{ x: number, y: number, w: number, h: number }} Rect */
/** @typedef {{ top: number, right: number, bottom: number, left: number }} Padding */
/** @typedef {{ w: number, h: number }} IntrinsicSize */
/** @typedef {{ kind: "fixed", value: number, min?: number, max?: number } | { kind: "fit", min?: number, max?: number } | { kind: "grow", value: number, min?: number, max?: number }} SizeSpec */
/** @typedef {{ value: unknown, size: SizeSpec, align?: "start" | "center" | "end" | "stretch", intrinsic?: IntrinsicSize, layout?: LayoutNode }} LayoutChild */
/** @typedef {{ kind: "row" | "column", children: LayoutChild[], gap: number, padding: Padding, align: "start" | "center" | "end" | "stretch" }} LayoutNode */
/** @typedef {{ value: unknown, rect: Rect, children: LayoutResult[] }} LayoutResult */

const ALIGN = Object.freeze({ start: true, center: true, end: true, stretch: true });

/** @param {number} value @param {string} name @returns {number} */
function cell(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) throw new TypeError(name + " must be a non-negative integer");
  return value;
}

/** @param {number} value @param {string} name @returns {number} */
function positive(value, name) {
  if (!Number.isFinite(value) || value <= 0) throw new TypeError(name + " must be positive");
  return value;
}

/** @param {number | undefined} value @param {string} name @returns {number | undefined} */
function limit(value, name) {
  if (value === undefined) return undefined;
  return cell(value, name);
}

/** @param {{ min?: number, max?: number } | undefined} options @returns {{ min?: number, max?: number }} */
function limits(options) {
  const min = limit(options && options.min, "min");
  const max = limit(options && options.max, "max");
  if (min !== undefined && max !== undefined && min > max) throw new TypeError("min must not exceed max");
  return { ...(min === undefined ? {} : { min }), ...(max === undefined ? {} : { max }) };
}

/** @param {number} value @param {{ min?: number, max?: number }} bound @returns {number} */
function clamp(value, bound) {
  if (bound.min !== undefined) value = Math.max(bound.min, value);
  if (bound.max !== undefined) value = Math.min(bound.max, value);
  return value;
}

/** @param {number} cells @param {{ min?: number, max?: number }} [options] @returns {SizeSpec} */
export function fixed(cells, options) {
  cell(cells, "fixed size");
  const bound = limits(options);
  return { kind: "fixed", value: cells, ...bound };
}

/** @param {{ min?: number, max?: number }} [options] @returns {SizeSpec} */
export function fit(options) {
  return { kind: "fit", ...limits(options) };
}

/** @param {number} [weight] @param {{ min?: number, max?: number }} [options] @returns {SizeSpec} */
export function grow(weight = 1, options) {
  positive(weight, "grow weight");
  return { kind: "grow", value: weight, ...limits(options) };
}

/** @param {unknown} value @param {SizeSpec} size @param {{ align?: "start" | "center" | "end" | "stretch", intrinsic?: IntrinsicSize, layout?: LayoutNode }} [options] @returns {LayoutChild} */
export function child(value, size, options = {}) {
  if (!size || (size.kind !== "fixed" && size.kind !== "fit" && size.kind !== "grow")) throw new TypeError("child needs a size specification");
  if (options.align !== undefined && !ALIGN[options.align]) throw new TypeError("child align is invalid");
  if (options.intrinsic !== undefined) checkIntrinsic(options.intrinsic);
  return { value, size, ...(options.align === undefined ? {} : { align: options.align }), ...(options.intrinsic === undefined ? {} : { intrinsic: options.intrinsic }), ...(options.layout === undefined ? {} : { layout: options.layout }) };
}

/** @param {"row" | "column"} kind @param {LayoutChild[]} children @param {{ gap?: number, padding?: number | Partial<Padding>, align?: "start" | "center" | "end" | "stretch" }} [options] @returns {LayoutNode} */
function container(kind, children, options = {}) {
  if (!Array.isArray(children)) throw new TypeError(kind + " children must be an array");
  const gap = options.gap === undefined ? 0 : cell(options.gap, "gap");
  const padding = normalizePadding(options.padding);
  const align = options.align === undefined ? "stretch" : options.align;
  if (!ALIGN[align]) throw new TypeError("container align is invalid");
  return { kind, children: children.slice(), gap, padding, align };
}

/** @param {LayoutChild[]} children @param {{ gap?: number, padding?: number | Partial<Padding>, align?: "start" | "center" | "end" | "stretch" }} [options] @returns {LayoutNode} */
export function row(children, options) {
  return container("row", children, options);
}

/** @param {LayoutChild[]} children @param {{ gap?: number, padding?: number | Partial<Padding>, align?: "start" | "center" | "end" | "stretch" }} [options] @returns {LayoutNode} */
export function column(children, options) {
  return container("column", children, options);
}

/** @param {number | Partial<Padding> | undefined} value @returns {Padding} */
function normalizePadding(value) {
  if (value === undefined) return { top: 0, right: 0, bottom: 0, left: 0 };
  if (typeof value === "number") {
    const all = cell(value, "padding");
    return { top: all, right: all, bottom: all, left: all };
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new TypeError("padding must be a number or an object");
  const out = {
    top: cell(value.top === undefined ? 0 : value.top, "padding.top"),
    right: cell(value.right === undefined ? 0 : value.right, "padding.right"),
    bottom: cell(value.bottom === undefined ? 0 : value.bottom, "padding.bottom"),
    left: cell(value.left === undefined ? 0 : value.left, "padding.left"),
  };
  for (const key of Object.keys(value)) if (!(key in out)) throw new TypeError("padding: unknown key " + key);
  return out;
}

/** @param {unknown} value @returns {void} */
function checkIntrinsic(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new TypeError("intrinsic size must be an object");
  const size = /** @type {{ w: number, h: number }} */ (value);
  cell(size.w, "intrinsic.w");
  cell(size.h, "intrinsic.h");
}

/** @param {Rect} rect @param {Rect} bounds @returns {Rect} */
export function clipRect(rect, bounds) {
  checkRect(rect, "rect");
  checkRect(bounds, "bounds");
  const x = Math.max(rect.x, bounds.x);
  const y = Math.max(rect.y, bounds.y);
  const right = Math.min(rect.x + rect.w, bounds.x + bounds.w);
  const bottom = Math.min(rect.y + rect.h, bounds.y + bounds.h);
  return { x, y, w: Math.max(0, right - x), h: Math.max(0, bottom - y) };
}

/** @param {LayoutNode} node @param {Rect} bounds @returns {LayoutResult} */
export function solve(node, bounds) {
  if (!node || (node.kind !== "row" && node.kind !== "column")) throw new TypeError("solve needs a row or column");
  checkRect(bounds, "bounds");
  const rect = { x: bounds.x, y: bounds.y, w: bounds.w, h: bounds.h };
  const p = node.padding;
  const left = Math.min(rect.x + rect.w, rect.x + p.left);
  const top = Math.min(rect.y + rect.h, rect.y + p.top);
  const right = Math.max(left, Math.min(rect.x + rect.w, rect.x + rect.w - p.right));
  const bottom = Math.max(top, Math.min(rect.y + rect.h, rect.y + rect.h - p.bottom));
  const inner = { x: left, y: top, w: right - left, h: bottom - top };
  const vertical = node.kind === "column";
  const main = vertical ? inner.h : inner.w;
  const cross = vertical ? inner.w : inner.h;
  for (const item of node.children) if (item.size.kind === "fit" && !item.intrinsic) throw new TypeError("fit child needs intrinsic size");
  const gapTotal = node.gap * Math.max(0, node.children.length - 1);
  const sizes = allocate(node.children, Math.max(0, main - gapTotal), vertical);
  const children = [];
  let at = vertical ? inner.y : inner.x;
  for (let i = 0; i < node.children.length; i++) {
    const item = /** @type {LayoutChild} */ (node.children[i]);
    const mainSize = /** @type {number} */ (sizes[i]);
    const alignment = item.align || node.align;
    const crossSize = crossSizeOf(item, cross, vertical, alignment);
    const crossAt = alignment === "center" ? Math.floor((cross - crossSize) / 2) : alignment === "end" ? cross - crossSize : 0;
    const childRect = vertical ? { x: inner.x + crossAt, y: at, w: crossSize, h: mainSize } : { x: at, y: inner.y + crossAt, w: mainSize, h: crossSize };
    children.push({ value: item.value, rect: clipRect(childRect, inner), children: item.layout ? solve(item.layout, clipRect(childRect, inner)).children : [] });
    at += mainSize + node.gap;
  }
  return { value: node, rect, children };
}

/** @param {LayoutChild} item @param {number} cross @param {boolean} vertical @param {"start" | "center" | "end" | "stretch"} alignment @returns {number} */
function crossSizeOf(item, cross, vertical, alignment) {
  if (alignment === "stretch") return cross;
  const intrinsic = item.intrinsic;
  if (!intrinsic) return 0;
  return Math.min(cross, vertical ? intrinsic.w : intrinsic.h);
}

/** @param {LayoutChild[]} children @param {number} total @param {boolean} vertical @returns {number[]} */
function allocate(children, total, vertical) {
  const out = children.map((item) => {
    const spec = item.size;
    const intrinsic = item.intrinsic;
    const wanted = spec.kind === "fixed" ? spec.value : spec.kind === "fit" ? (intrinsic ? vertical ? intrinsic.h : intrinsic.w : 0) : 0;
    return clamp(wanted, spec);
  });
  let used = 0;
  for (let i = 0; i < children.length; i++) {
    const item = /** @type {LayoutChild} */ (children[i]);
    if (item.size.kind === "grow") {
      out[i] = item.size.min === undefined ? 0 : item.size.min;
      continue;
    }
    const available = Math.max(0, total - used);
    out[i] = Math.min(/** @type {number} */ (out[i]), available);
    used += /** @type {number} */ (out[i]);
  }
  for (let i = 0; i < children.length; i++) {
    const item = /** @type {LayoutChild} */ (children[i]);
    if (item.size.kind === "grow") used += /** @type {number} */ (out[i]);
  }
  let remaining = Math.max(0, total - used);
  const active = children.map((item, i) => item.size.kind === "grow" && (item.size.max === undefined || /** @type {number} */ (out[i]) < item.size.max) ? i : -1).filter((i) => i >= 0);
  while (remaining > 0 && active.length > 0) {
    let scale = 0;
    for (const i of active) scale = Math.max(scale, /** @type {{ value: number }} */ (/** @type {LayoutChild} */ (children[i]).size).value);
    let weights = 0;
    for (const i of active) weights += /** @type {{ value: number }} */ (/** @type {LayoutChild} */ (children[i]).size).value / scale;
    if (weights <= 0) break;
    const additions = active.map((i) => {
      const exact = remaining * (/** @type {{ value: number }} */ (/** @type {LayoutChild} */ (children[i]).size).value / scale) / weights;
      return { i, whole: Math.floor(exact), fraction: exact - Math.floor(exact) };
    });
    let given = 0;
    for (const part of additions) {
      const item = /** @type {LayoutChild} */ (children[part.i]);
      const max = item.size.max;
      const add = max === undefined ? part.whole : Math.min(part.whole, max - /** @type {number} */ (out[part.i]));
      out[part.i] = /** @type {number} */ (out[part.i]) + add;
      given += add;
    }
    let left = remaining - given;
    additions.sort((a, b) => b.fraction - a.fraction || a.i - b.i);
    for (const part of additions) {
      if (left === 0) break;
      const item = /** @type {LayoutChild} */ (children[part.i]);
      const max = item.size.max;
      if (max !== undefined && /** @type {number} */ (out[part.i]) >= max) continue;
      out[part.i] = /** @type {number} */ (out[part.i]) + 1;
      left--;
    }
    const progress = remaining - left;
    remaining = left;
    for (let k = active.length - 1; k >= 0; k--) {
      const i = /** @type {number} */ (active[k]);
      const item = /** @type {LayoutChild} */ (children[i]);
      const max = item.size.max;
      if (max !== undefined && /** @type {number} */ (out[i]) >= max) active.splice(k, 1);
    }
    if (progress === 0) break;
  }
  return out;
}

/** @param {Rect} rect @param {string} name @returns {void} */
function checkRect(rect, name) {
  if (!rect || !Number.isSafeInteger(rect.x) || !Number.isSafeInteger(rect.y) || !Number.isSafeInteger(rect.w) || !Number.isSafeInteger(rect.h) || rect.w < 0 || rect.h < 0) throw new TypeError(name + " must have integer coordinates and non-negative size");
}
