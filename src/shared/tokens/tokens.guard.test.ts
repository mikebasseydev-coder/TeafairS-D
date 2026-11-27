// Zero raw colour outside src/shared/tokens/ (Spec B §4.2, FIGMA.md intro).
import * as fs from "fs";
import * as path from "path";

const SRC = path.resolve(__dirname, "../..");
const TOKENS = path.join(SRC, "shared", "tokens") + path.sep;
const EMBLEM = path.join(SRC, "shared", "ui", "Emblem.tsx");
const SELF = __filename;

function walk(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) return walk(p);
    return /\.(tsx?|jsx?|css)$/.test(e.name) ? [p] : [];
  });
}

const HEX = /#[0-9a-fA-F]{3,8}\b/;
const COLOUR_FN = /\b(rgba?|hsla?)\s*\(/;
const STOCK =
  /\b(?:bg|text|border(?:-[trblxy])?|ring|fill|stroke|from|to|via|divide|outline|shadow|accent|decoration|placeholder|caret)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|black|white)(?:-\d{2,3})?\b/;
const PRIMITIVE_CLASS = /\bteafair-[a-z]/;

const files = walk(SRC).filter((f) => f !== SELF);
const outsideTokens = files.filter((f) => !f.startsWith(TOKENS));

function offenders(list: string[], re: RegExp): string[] {
  const hits: string[] = [];
  for (const f of list) {
    fs.readFileSync(f, "utf8")
      .split(/\r?\n/)
      .forEach((line, i) => {
        if (re.test(line)) hits.push(`${path.relative(SRC, f)}:${i + 1}: ${line.trim()}`);
      });
  }
  return hits;
}

describe("tokens guard", () => {
  it("scans a non-trivial tree", () => {
    expect(outsideTokens.length).toBeGreaterThan(10);
  });
  it("has no hex colour outside tokens/", () => {
    expect(offenders(outsideTokens, HEX)).toEqual([]);
  });
  it("has no rgb()/hsl() outside tokens/", () => {
    expect(offenders(outsideTokens, COLOUR_FN)).toEqual([]);
  });
  it("has no stock palette class anywhere", () => {
    expect(offenders(files, STOCK)).toEqual([]);
  });
  it("has no teafair-* primitive class outside tokens/ and the emblem", () => {
    expect(offenders(outsideTokens.filter((f) => f !== EMBLEM), PRIMITIVE_CLASS)).toEqual([]);
  });
});
