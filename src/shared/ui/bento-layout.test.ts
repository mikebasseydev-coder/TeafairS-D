import { layoutBento } from "./bento-layout";
import { bentoColumns, skeletonRowCount } from "./sizes";

const opts = (columns: number, width: number) => ({ columns, width, gap: 12, rowHeight: 100 });

describe("Bento layout (Spec B §4.1)", () => {
  it("is 2 columns on a 390 px phone and 4 on a 768 px tablet", () => {
    expect(bentoColumns(390)).toBe(2);
    expect(bentoColumns(767)).toBe(2);
    expect(bentoColumns(768)).toBe(4);
    expect(bentoColumns(1024)).toBe(4);
  });
  it("a 2x2 tile spans the phone's width", () => {
    const { placed } = layoutBento(["2x2"], opts(2, 360));
    expect(placed[0]).toMatchObject({ x: 0, width: 360, height: 212 });
  });
  it("fills the hole beside a 2x2 tile on a tablet", () => {
    const { placed, height } = layoutBento(["2x2", "1x1", "1x1", "1x1", "1x1"], opts(4, 744));
    expect(placed.map((p) => [p.col, p.row])).toEqual([
      [0, 0],
      [2, 0],
      [3, 0],
      [2, 1],
      [3, 1],
    ]);
    expect(height).toBe(212);
  });
  it("never overlaps and never leaves the grid", () => {
    const spans = ["1x1", "2x1", "2x2", "1x1", "2x1", "1x1", "2x2", "1x1"] as const;
    for (const columns of [2, 4]) {
      const { placed } = layoutBento([...spans], opts(columns, 700));
      const seen = new Set<string>();
      for (const p of placed) {
        expect(p.col + p.cols).toBeLessThanOrEqual(columns);
        for (let r = p.row; r < p.row + p.rows; r++)
          for (let c = p.col; c < p.col + p.cols; c++) {
            const k = `${r}:${c}`;
            expect(seen.has(k)).toBe(false);
            seen.add(k);
          }
      }
    }
  });
});

describe("skeleton rows", () => {
  it.each([
    [1, 4],
    [4, 4],
    [5, 5],
    [6, 6],
    [20, 6],
  ])("asking for %s renders %s", (asked, rows) => {
    expect(skeletonRowCount(asked)).toBe(rows);
  });
});
