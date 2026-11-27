// Skeleton primitives (Spec B §4.3). `pulse` (default) is a NativeWind opacity
// pulse on a plain block, for dense lists. `shimmer` is moti's skeleton, for
// one hero, header or detail surface per screen. Both use the theme's skeleton
// tokens, stop when the OS asks for reduced motion, and are hidden from screen
// readers; the region around them announces "Loading" once.
import type { ReactNode } from "react";
import { View, type DimensionValue } from "react-native";
import { useReducedMotion } from "react-native-reanimated";
import { Skeleton as MotiSkeleton } from "moti/skeleton";
import { BENTO_ROW_HEIGHT, LIST_ROW_HEIGHT, skeletonRowCount } from "./sizes";
import { useTheme } from "./theme";

export type SkeletonVariant = "pulse" | "shimmer";

type BlockProps = { variant?: SkeletonVariant; width?: DimensionValue; height: number; radius?: number };

const hidden = { accessibilityElementsHidden: true, importantForAccessibility: "no-hide-descendants" as const, "aria-hidden": true };

/** One block. */
export function Skeleton({ variant = "pulse", width = "100%", height, radius = 6 }: BlockProps) {
  const reduced = useReducedMotion();
  const t = useTheme();
  if (variant === "shimmer" && !reduced) {
    return (
      <View {...hidden} testID="skeleton-block" style={{ width, height }}>
        <MotiSkeleton
          colors={[t.colors.skeleton, t.colors["skeleton-highlight"], t.colors.skeleton]}
          width="100%"
          height={height}
          radius={radius}
        />
      </View>
    );
  }
  return (
    <View
      {...hidden}
      testID="skeleton-block"
      className={`bg-skeleton ${reduced ? "" : "animate-pulse"}`}
      style={{ width, height, borderRadius: radius }}
    />
  );
}

/** The loading region: one accessible element that says "Loading". */
export function SkeletonRegion({ children, testID, label = "Loading" }: { children: ReactNode; testID?: string; label?: string }) {
  return (
    <View testID={testID} accessible accessibilityRole="progressbar" accessibilityLabel={label} accessibilityLiveRegion="polite">
      {children}
    </View>
  );
}

const LINE_WIDTHS: DimensionValue[] = ["92%", "78%", "64%", "84%", "56%"];

/** Text lines; the last line is shorter, as text is. */
export function SkeletonText({ lines = 3, variant = "pulse", lineHeight = 14 }: { lines?: number; variant?: SkeletonVariant; lineHeight?: number }) {
  return (
    <View style={{ gap: 8 }}>
      {Array.from({ length: lines }, (_, i) => (
        <Skeleton key={i} variant={variant} height={lineHeight} width={i === lines - 1 ? "48%" : LINE_WIDTHS[i % LINE_WIDTHS.length]} />
      ))}
    </View>
  );
}

/** The ListRow footprint: same height, same padding, same hairline. */
export function SkeletonListRow({ variant = "pulse" }: { variant?: SkeletonVariant }) {
  return (
    <View
      testID="skeleton-row"
      className="flex-row items-center border-b border-hairline bg-surface px-4"
      style={{ height: LIST_ROW_HEIGHT, gap: 12 }}
    >
      <View className="flex-1" style={{ gap: 8 }}>
        <Skeleton variant={variant} height={16} width="62%" />
        <Skeleton variant={variant} height={12} width="40%" />
      </View>
      <Skeleton variant={variant} height={16} width={64} />
    </View>
  );
}

/** A list's loading state: 4–6 rows, never a screen of them. */
export function SkeletonList({ rows = 5, variant = "pulse", testID }: { rows?: number; variant?: SkeletonVariant; testID?: string }) {
  return (
    <SkeletonRegion testID={testID}>
      {Array.from({ length: skeletonRowCount(rows) }, (_, i) => (
        <SkeletonListRow key={i} variant={variant} />
      ))}
    </SkeletonRegion>
  );
}

/** The BentoTile body footprint: a title line and a figure. */
export function SkeletonTile({ variant = "pulse", rows = 1 }: { variant?: SkeletonVariant; rows?: number }) {
  const figure = Math.max(28, (BENTO_ROW_HEIGHT - 64) * rows);
  return (
    <SkeletonRegion>
      <View style={{ gap: 12 }}>
        <Skeleton variant={variant} height={12} width="55%" />
        <Skeleton variant={variant} height={Math.min(figure, 28)} width="70%" />
        {rows > 1 ? <SkeletonText lines={3} variant={variant} /> : null}
      </View>
    </SkeletonRegion>
  );
}
