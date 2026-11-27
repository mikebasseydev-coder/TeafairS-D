// Every colour pair a theme uses, with its WCAG minimum (Spec B §4.2).
// Hairlines are decorative separators and are deliberately absent.
import { primitives } from "./primitives";
import { contrastRatio, MIN_NON_TEXT, MIN_TEXT } from "./contrast";
import { THEMES, TONES, themeTokens, toneTokens, type ThemeName } from "./semantic";

type Pair = { fg: string; bg: string; min: number; why: string };

function pairsFor(theme: ThemeName): Pair[] {
  const t = themeTokens[theme];
  const c = (k: keyof typeof t) => primitives[t[k]];
  const out: Pair[] = [];
  const add = (fg: string, bg: string, min: number, why: string) => out.push({ fg, bg, min, why });

  for (const ground of ["canvas", "surface"] as const) {
    add(c("ink"), c(ground), MIN_TEXT, `ink on ${ground}`);
    add(c("control"), c(ground), MIN_NON_TEXT, `control on ${ground}`);
    add(c("focus"), c(ground), MIN_NON_TEXT, `focus on ${ground}`);
    add(c("action"), c(ground), MIN_NON_TEXT, `action fill on ${ground}`);
    add(c("action-strong"), c(ground), MIN_NON_TEXT, `action-strong fill on ${ground}`);
  }
  add(c("ink-muted"), c("surface"), MIN_TEXT, "ink-muted on surface");
  // On the standard canvas muted text is 4.40:1: only 14 px semibold or larger there (Spec B §4.2).
  add(c("ink-muted"), c("canvas"), theme === "standard" ? MIN_NON_TEXT : MIN_TEXT, "ink-muted on canvas");
  add(c("on-action"), c("action"), MIN_TEXT, "on-action on action");
  add(c("on-action-strong"), c("action-strong"), MIN_TEXT, "on-action-strong on action-strong");

  for (const tone of TONES) {
    const s = toneTokens[theme][tone];
    for (const ground of [c("surface"), c("canvas"), primitives[s.subtle]]) {
      add(primitives[s.text], ground, MIN_TEXT, `${tone} text`);
    }
    // Marks sit on surfaces or on their own subtle background, never on the bare canvas.
    for (const ground of [c("surface"), primitives[s.subtle]]) {
      add(primitives[s.mark], ground, MIN_NON_TEXT, `${tone} mark`);
    }
  }
  return out;
}

describe.each(THEMES)("the %s theme", (theme) => {
  it.each(pairsFor(theme).map((p) => [p.why, p] as const))("%s meets its minimum", (_why, p) => {
    expect(contrastRatio(p.fg, p.bg)).toBeGreaterThanOrEqual(p.min);
  });
});

describe("the measured ratios FIGMA.md §2 records", () => {
  const r = (a: keyof typeof primitives, b: keyof typeof primitives) =>
    Math.round(contrastRatio(primitives[a], primitives[b]) * 100) / 100;
  it.each([
    ["ink", "white", 17.85],
    ["ink", "canvas", 16.49],
    ["slate", "white", 4.76],
    ["slate", "canvas", 4.4],
    ["white", "botanical", 13.13],
    ["ink", "leaf", 5.48],
    ["white", "leaf", 3.26],
    ["ink", "amber", 5.6],
    ["amber", "canvas", 2.94],
    ["red", "white", 6.47],
    ["blue", "white", 5.93],
    ["red-soft", "botanical", 4.75],
    ["sky", "botanical", 6.13],
    ["slate", "botanical", 2.76],
    ["mist", "white", 1.23],
  ] as const)("%s on %s is %s:1", (a, b, ratio) => {
    expect(r(a, b)).toBe(ratio);
  });
});
