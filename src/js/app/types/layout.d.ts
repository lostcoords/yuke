import type { Rect } from "./core.js";

export interface Padding {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

export interface IntrinsicSize {
  w: number;
  h: number;
}

export type SizeSpec =
  | { kind: "fixed"; value: number; min?: number; max?: number }
  | { kind: "fit"; min?: number; max?: number }
  | { kind: "grow"; value: number; min?: number; max?: number };

export interface LayoutChild {
  value: unknown;
  size: SizeSpec;
  align?: "start" | "center" | "end" | "stretch";
  intrinsic?: IntrinsicSize;
  layout?: LayoutNode;
}

export interface LayoutNode {
  kind: "row" | "column";
  children: LayoutChild[];
  gap: number;
  padding: Padding;
  align: "start" | "center" | "end" | "stretch";
}

export interface LayoutResult {
  value: unknown;
  rect: Rect;
  children: LayoutResult[];
}
