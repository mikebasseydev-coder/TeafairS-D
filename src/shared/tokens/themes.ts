// Resolves a theme to concrete colours and to the CSS variables the NativeWind
// preset reads. Switching theme swaps variables; no class changes.
import { primitives, type PrimitiveName } from "./primitives";
import {
  SEMANTIC_TOKENS,
  TONES,
  themeTokens,
  toneTokens,
  type SemanticToken,
  type SemanticTone,
  type ThemeName,
} from "./semantic";

export type ResolvedTone = { mark: string; text: string; subtle: string };
export type ResolvedTheme = {
  name: ThemeName;
  colors: Record<SemanticToken, string>;
  tones: Record<SemanticTone, ResolvedTone>;
};

const hex = (p: PrimitiveName): string => primitives[p];

export function resolveTheme(name: ThemeName): ResolvedTheme {
  const colors = {} as Record<SemanticToken, string>;
  for (const t of SEMANTIC_TOKENS) colors[t] = hex(themeTokens[name][t]);
  const tones = {} as Record<SemanticTone, ResolvedTone>;
  for (const tone of TONES) {
    const s = toneTokens[name][tone];
    tones[tone] = { mark: hex(s.mark), text: hex(s.text), subtle: hex(s.subtle) };
  }
  return { name, colors, tones };
}

/** The CSS custom properties of a theme, e.g. `--canvas`, `--tone-danger-text`. */
export function themeVariables(name: ThemeName): Record<`--${string}`, string> {
  const r = resolveTheme(name);
  const out: Record<`--${string}`, string> = {};
  for (const t of SEMANTIC_TOKENS) out[`--${t}`] = r.colors[t];
  for (const tone of TONES) {
    out[`--tone-${tone}-mark`] = r.tones[tone].mark;
    out[`--tone-${tone}-text`] = r.tones[tone].text;
    out[`--tone-${tone}-subtle`] = r.tones[tone].subtle;
  }
  return out;
}
