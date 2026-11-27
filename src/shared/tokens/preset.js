// The NativeWind / Tailwind preset (FIGMA.md §5, Spec B §4.2). Tailwind loads
// its config through jiti, so the TypeScript sources below resolve here.
const { primitives } = require("./primitives");
const { SEMANTIC_TOKENS, TONES } = require("./semantic");

const v = (name) => `var(--${name})`;

const semantic = Object.fromEntries(SEMANTIC_TOKENS.map((t) => [t, v(t)]));

// bg-tone-<tone> and border-tone-<tone> are the mark; bg-tone-<tone>-subtle the
// subtle background; text-tone-<tone> the tone's text colour (textColor below).
const toneColors = {};
const toneText = {};
for (const tone of TONES) {
  toneColors[`tone-${tone}`] = v(`tone-${tone}-mark`);
  toneColors[`tone-${tone}-subtle`] = v(`tone-${tone}-subtle`);
  toneText[`tone-${tone}`] = v(`tone-${tone}-text`);
}

/** @type {import('tailwindcss').Config} */
module.exports = {
  theme: {
    extend: {
      colors: {
        teafair: { ...primitives },
        ...semantic,
        ...toneColors,
      },
      textColor: toneText,
      fontSize: {
        // the fixed Swiss scale: 12, 14, 16, 20, 24, 32
        xs: ["12px", "16px"],
        sm: ["14px", "20px"],
        base: ["16px", "24px"],
        lg: ["20px", "28px"],
        xl: ["24px", "32px"],
        "2xl": ["32px", "40px"],
      },
    },
  },
};
