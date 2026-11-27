// The semantic layer (FIGMA.md §3, Spec B §4.2): what components use. Each
// token resolves to a primitive per theme. Components never name a primitive.
import type { OpaquePrimitive, PrimitiveName } from "./primitives";

export const THEMES = ["standard", "daylight", "dark"] as const;
export type ThemeName = (typeof THEMES)[number];

export const SEMANTIC_TOKENS = [
  "canvas",
  "surface",
  "scrim",
  "ink",
  "ink-muted",
  "hairline",
  "control",
  "focus",
  "action",
  "on-action",
  "action-strong",
  "on-action-strong",
  "skeleton",
  "skeleton-highlight",
] as const;
export type SemanticToken = (typeof SEMANTIC_TOKENS)[number];

export const TONES = ["neutral", "brand", "success", "warning", "danger", "info", "pending"] as const;
export type SemanticTone = (typeof TONES)[number];

/** A tone's three colours: the mark (icon, border, indicator), its text, its subtle background. */
export type ToneSlots = { mark: OpaquePrimitive; text: OpaquePrimitive; subtle: OpaquePrimitive };

export const themeTokens: Record<ThemeName, Record<SemanticToken, PrimitiveName>> = {
  standard: {
    canvas: "canvas",
    surface: "white",
    scrim: "scrim",
    ink: "ink",
    "ink-muted": "slate",
    hairline: "mist",
    control: "slate",
    focus: "botanical",
    action: "leaf",
    "on-action": "ink",
    "action-strong": "botanical",
    "on-action-strong": "white",
    skeleton: "mist",
    "skeleton-highlight": "canvas",
  },
  daylight: {
    canvas: "white",
    surface: "white",
    scrim: "scrim",
    ink: "ink",
    "ink-muted": "ink",
    hairline: "slate",
    control: "ink",
    focus: "ink",
    action: "botanical",
    "on-action": "white",
    "action-strong": "ink",
    "on-action-strong": "white",
    skeleton: "mist",
    "skeleton-highlight": "white",
  },
  dark: {
    canvas: "ink",
    surface: "botanical",
    scrim: "scrim",
    ink: "canvas",
    "ink-muted": "mist",
    hairline: "mist",
    control: "mist",
    focus: "leaf",
    action: "leaf",
    "on-action": "ink",
    "action-strong": "canvas",
    "on-action-strong": "ink",
    skeleton: "ink",
    "skeleton-highlight": "botanical",
  },
};

const lightTones: Record<SemanticTone, ToneSlots> = {
  neutral: { mark: "slate", text: "ink", subtle: "canvas" },
  brand: { mark: "leaf", text: "botanical", subtle: "canvas" },
  success: { mark: "leaf", text: "botanical", subtle: "canvas" },
  // amber is 2.94:1 on canvas, below the 3:1 mark rule, so warning's subtle background is white
  warning: { mark: "amber", text: "ink", subtle: "white" },
  danger: { mark: "red", text: "red", subtle: "red-tint" },
  info: { mark: "blue", text: "blue", subtle: "blue-tint" },
  pending: { mark: "slate", text: "ink", subtle: "canvas" },
};

export const toneTokens: Record<ThemeName, Record<SemanticTone, ToneSlots>> = {
  standard: lightTones,
  daylight: lightTones,
  dark: {
    // slate is 2.76:1 on botanical, so neutral and pending marks are mist on dark
    neutral: { mark: "mist", text: "mist", subtle: "ink" },
    brand: { mark: "leaf", text: "canvas", subtle: "ink" },
    success: { mark: "leaf", text: "canvas", subtle: "ink" },
    warning: { mark: "amber", text: "canvas", subtle: "ink" },
    danger: { mark: "red-soft", text: "red-soft", subtle: "ink" },
    info: { mark: "sky", text: "sky", subtle: "ink" },
    pending: { mark: "mist", text: "canvas", subtle: "ink" },
  },
};

/** Non-colour differences between themes (FIGMA.md §3, Spec B §4.2). */
export const themeMetrics: Record<ThemeName, { badgeBorder: number; focusRing: number; minTouch: number }> = {
  standard: { badgeBorder: 1, focusRing: 2, minTouch: 44 },
  daylight: { badgeBorder: 1.5, focusRing: 3, minTouch: 48 },
  dark: { badgeBorder: 1, focusRing: 2, minTouch: 44 },
};

/** The fixed icon of each tone (FIGMA.md §3). Status is never colour alone. */
export const toneIcon: Record<SemanticTone, "dot" | "leaf" | "check" | "triangle" | "octagon" | "info" | "clock"> = {
  neutral: "dot",
  brand: "leaf",
  success: "check",
  warning: "triangle",
  danger: "octagon",
  info: "info",
  pending: "clock",
};
