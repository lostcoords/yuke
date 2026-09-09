// yuke:layout — a small terminal-cell layout solver for retained views.

/** @import { Rect } from "./types/core.js" */
/** @import { IntrinsicSize, LayoutChild, LayoutNode, LayoutResult, Padding, SizeSpec } from "./types/layout.js" */

const ALIGN = Object.freeze({ start: true, center: true, end: true, stretch: true });

/** @param {number} value @param {string} name @returns {number} */
function cell(value, name) {
  if (!Number.isSafeInteger(value) || value < 0) throw new TypeError(name + " must be a non-negative integer");
  return value;
}

/** @param {{ min?: number, max?: number } | undefined} options @returns {{ min?: number, max?: number }} */
function limits(options) {
  const min = options && options.min, max = options && options.max;
  if (min !== undefined) cell(min, "min");
  if (max !== undefined) cell(max, "max");
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
  if (!Number.isFinite(weight) || weight <= 0) throw new TypeError("grow weight must be positive");
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
    const wanted = item.intrinsic ? vertical ? item.intrinsic.w : item.intrinsic.h : 0;
    const crossSize = alignment === "stretch" ? cross : Math.min(cross, wanted);
    const crossAt = alignment === "center" ? Math.floor((cross - crossSize) / 2) : alignment === "end" ? cross - crossSize : 0;
    const childRect = vertical ? { x: inner.x + crossAt, y: at, w: crossSize, h: mainSize } : { x: at, y: inner.y + crossAt, w: mainSize, h: crossSize };
    const clipped = clipRect(childRect, inner);
    children.push({ value: item.value, rect: clipped, children: item.layout ? solve(item.layout, clipped).children : [] });
    at += mainSize + node.gap;
  }
  return { value: node, rect, children };
}

/** @param {LayoutChild[]} children @param {number} total @param {boolean} vertical @returns {number[]} */
function allocate(children, total, vertical) {
  /** @type {{ i: number, weight: number, room: number, fraction: number }[]} */
  let active = [];
  let remaining = total;
  const out = children.map(({ size, intrinsic }, i) => {
    if (size.kind === "grow") {
      const min = size.min ?? 0;
      active.push({ i, weight: size.value, room: (size.max ?? Infinity) - min, fraction: 0 });
      return min;
    }
    const wanted = size.kind === "fixed" ? size.value : intrinsic ? vertical ? intrinsic.h : intrinsic.w : 0;
    const used = Math.min(clamp(wanted, size), remaining);
    remaining -= used;
    return used;
  });
  // The solver clips overflow when fixed sizes and grow minimums exceed the bounds.
  for (const part of active) remaining -= /** @type {number} */ (out[part.i]);
  remaining = Math.max(0, remaining);
  active = active.filter(part => part.room > 0);
  while (remaining > 0 && active.length > 0) {
    let scale = 0;
    for (const part of active) scale = Math.max(scale, part.weight);
    const weights = active.reduce((sum, part) => sum + part.weight / scale, 0);
    let left = remaining;
    for (const part of active) {
      const exact = remaining * (part.weight / scale) / weights;
      part.fraction = exact - Math.floor(exact);
      const add = Math.min(Math.floor(exact), part.room);
      out[part.i] = /** @type {number} */ (out[part.i]) + add;
      part.room -= add;
      left -= add;
    }
    for (const part of active.slice().sort((a, b) => b.fraction - a.fraction || a.i - b.i)) {
      if (left === 0) break;
      if (part.room <= 0) continue;
      out[part.i] = /** @type {number} */ (out[part.i]) + 1;
      part.room--;
      left--;
    }
    if (left === remaining) break;
    remaining = left;
    active = active.filter(part => part.room > 0);
  }
  return out;
}

/** @param {Rect} rect @param {string} name @returns {void} */
function checkRect(rect, name) {
  if (!rect || !Number.isSafeInteger(rect.x) || !Number.isSafeInteger(rect.y) || !Number.isSafeInteger(rect.w) || !Number.isSafeInteger(rect.h) || rect.w < 0 || rect.h < 0) throw new TypeError(name + " must have integer coordinates and non-negative size");
}
