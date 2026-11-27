// Packs Bento tiles into a column grid, first fit, top-left first. Pure, so it
// is unit-tested; BentoGrid positions tiles from its result.

export type BentoSpan = "1x1" | "2x1" | "2x2";

export type Placed = { x: number; y: number; width: number; height: number; col: number; row: number; cols: number; rows: number };

const SIZE: Record<BentoSpan, [number, number]> = { "1x1": [1, 1], "2x1": [2, 1], "2x2": [2, 2] };

export function layoutBento(
  spans: BentoSpan[],
  opts: { columns: number; width: number; gap: number; rowHeight: number },
): { placed: Placed[]; height: number } {
  const { columns, width, gap, rowHeight } = opts;
  const cellW = (width - gap * (columns - 1)) / columns;
  const grid: boolean[][] = [];
  const free = (r: number, c: number) => !(grid[r]?.[c] ?? false);
  const placed: Placed[] = [];
  let maxRow = 0;
  for (const span of spans) {
    const [w0, h] = SIZE[span];
    const w = Math.min(w0, columns);
    let done = false;
    for (let r = 0; !done; r++) {
      for (let c = 0; c + w <= columns && !done; c++) {
        let fits = true;
        for (let dr = 0; dr < h && fits; dr++) for (let dc = 0; dc < w && fits; dc++) fits = free(r + dr, c + dc);
        if (!fits) continue;
        for (let dr = 0; dr < h; dr++) {
          grid[r + dr] ??= [];
          for (let dc = 0; dc < w; dc++) grid[r + dr][c + dc] = true;
        }
        placed.push({
          col: c,
          row: r,
          cols: w,
          rows: h,
          x: c * (cellW + gap),
          y: r * (rowHeight + gap),
          width: w * cellW + (w - 1) * gap,
          height: h * rowHeight + (h - 1) * gap,
        });
        maxRow = Math.max(maxRow, r + h);
        done = true;
      }
    }
  }
  return { placed, height: maxRow === 0 ? 0 : maxRow * rowHeight + (maxRow - 1) * gap };
}
