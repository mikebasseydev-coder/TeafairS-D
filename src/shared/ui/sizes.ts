// Size constants shared by each component and its skeleton, so nothing shifts
// when the data arrives (Spec B §4.3).

export const LIST_ROW_HEIGHT = 72;

/** List skeletons render 4–6 rows, never a full screen of them. */
export const SKELETON_ROWS_MIN = 4;
export const SKELETON_ROWS_MAX = 6;
export function skeletonRowCount(requested = 5): number {
  return Math.min(SKELETON_ROWS_MAX, Math.max(SKELETON_ROWS_MIN, Math.round(requested)));
}

/** Bento (Spec B §4.1): 2 columns on a phone, 4 from 768 px; gaps of 12. */
export const BENTO_GAP = 12;
export const BENTO_ROW_HEIGHT = 132;
export const BENTO_TABLET_MIN_WIDTH = 768;
export function bentoColumns(width: number): 2 | 4 {
  return width >= BENTO_TABLET_MIN_WIDTH ? 4 : 2;
}
