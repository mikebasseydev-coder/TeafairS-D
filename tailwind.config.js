// The values live in src/shared/tokens/ (FIGMA.md is their source); this file
// only wires the preset in.
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./src/**/*.{ts,tsx}"],
  presets: [require("nativewind/preset"), require("./src/shared/tokens/preset")],
  theme: { extend: {} },
  plugins: [],
};
