// Bento Grid (Spec B §4.1): 1x1, 2x1 and 2x2 tiles; 2 columns on a phone, 4
// from 768 px; gaps of 12; surface fills with a hairline, never shadows.
// Each tile is isolated: it owns its loading, error and empty states, and a
// render error inside one tile is caught there, so its neighbours render.
import { Children, Component, isValidElement, useState, type ReactElement, type ReactNode } from "react";
import { Pressable, View, useWindowDimensions } from "react-native";
import { layoutBento, type BentoSpan } from "./bento-layout";
import { SkeletonTile, type SkeletonVariant } from "./Skeleton";
import { BENTO_GAP, BENTO_ROW_HEIGHT, bentoColumns } from "./sizes";
import { Text } from "./Text";
import { ToneIcon } from "./ToneIcon";
import { webData } from "./web-data";

/** A tile's fetch state, decided explicitly, never by `data == null` (Spec B §4.3). */
export type TileState =
  | { status: "loading"; hasData: boolean }
  | { status: "ready" }
  | { status: "empty"; message: string }
  | { status: "error"; message: string };

export type BentoTileProps = {
  title: string;
  span?: BentoSpan;
  state: TileState;
  onRetry?: () => void;
  skeleton?: SkeletonVariant;
  children?: ReactNode;
  testID?: string;
};

/** A tile's own error, compact enough for a 1x1 tile: words, the danger icon, and Retry. */
function TileError({ message, onRetry }: { message?: string; onRetry?: () => void }) {
  return (
    <View accessibilityRole="alert" style={{ gap: 4 }}>
      <View className="flex-row items-center" style={{ gap: 6 }}>
        <ToneIcon tone="danger" size={16} />
        <Text variant="label" className="text-tone-danger">
          Could not load
        </Text>
      </View>
      {message ? (
        <Text variant="caption" numberOfLines={2}>
          {message}
        </Text>
      ) : null}
      {onRetry ? (
        <Pressable accessibilityRole="button" accessibilityLabel="Retry" onPress={onRetry} hitSlop={8} className="self-start py-1">
          <Text variant="label" className="underline">
            Retry
          </Text>
        </Pressable>
      ) : null}
    </View>
  );
}

class TileBoundary extends Component<{ children: ReactNode; onRetry?: () => void }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <TileError
        onRetry={() => {
          this.setState({ failed: false });
          this.props.onRetry?.();
        }}
      />
    );
  }
}

export function BentoTile({ title, span = "1x1", state, onRetry, skeleton = "pulse", children, testID }: BentoTileProps) {
  let body: ReactNode;
  if (state.status === "loading" && !state.hasData) {
    body = <SkeletonTile variant={skeleton} rows={span === "2x2" ? 2 : 1} />;
  } else if (state.status === "error") {
    body = <TileError message={state.message} onRetry={onRetry} />;
  } else if (state.status === "empty") {
    body = (
      <Text variant="body" color="muted">
        {state.message}
      </Text>
    );
  } else {
    body = <TileBoundary onRetry={onRetry}>{children}</TileBoundary>;
  }
  return (
    <View testID={testID} {...webData({ span, status: state.status })} className="flex-1 overflow-hidden rounded-lg border border-hairline bg-surface p-4" style={{ gap: 8 }}>
      <Text variant="label" color="muted" numberOfLines={1} className="shrink-0">
        {title}
      </Text>
      {body}
    </View>
  );
}

export function BentoGrid({ children, testID }: { children: ReactNode; testID?: string }) {
  const { width: windowWidth } = useWindowDimensions();
  const [width, setWidth] = useState(0);
  const tiles = Children.toArray(children).filter(isValidElement) as ReactElement<BentoTileProps>[];
  const columns = bentoColumns(windowWidth);
  const { placed, height } = layoutBento(
    tiles.map((t) => t.props.span ?? "1x1"),
    { columns, width: Math.max(width, 1), gap: BENTO_GAP, rowHeight: BENTO_ROW_HEIGHT },
  );
  return (
    <View testID={testID} {...webData({ columns: String(columns) })} onLayout={(e) => setWidth(e.nativeEvent.layout.width)} style={{ height, width: "100%" }}>
      {width > 0
        ? tiles.map((tile, i) => (
            <View key={tile.key ?? i} style={{ position: "absolute", left: placed[i].x, top: placed[i].y, width: placed[i].width, height: placed[i].height }}>
              {tile}
            </View>
          ))
        : null}
    </View>
  );
}
