// The Teafair emblem palette (FIGMA.md §1). The only hex values in the app.
// A value changes here and in FIGMA.md together, with contrast.test.ts
// updated in the same commit (Spec B §4.2).

export const primitives = {
  leaf: "#629E28",
  botanical: "#1B3624",
  amber: "#D97706",
  canvas: "#F4F6F9",
  white: "#FFFFFF",
  scrim: "rgba(17, 24, 39, 0.35)", // #111827 at 35%
  ink: "#0F172A",
  slate: "#64748B",
  mist: "#E2E8F0",
  red: "#B91C1C",
  "red-soft": "#F87171",
  "red-tint": "#FEF2F2",
  blue: "#0369A1",
  sky: "#38BDF8",
  "blue-tint": "#F0F9FF",
} as const;

export type PrimitiveName = keyof typeof primitives;

/** Primitives that are opaque hex colours (everything but the scrim). */
export type OpaquePrimitive = Exclude<PrimitiveName, "scrim">;

export const PRIMITIVE_NAMES = Object.keys(primitives) as PrimitiveName[];
