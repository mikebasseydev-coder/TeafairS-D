// A 4-digit PIN entry. The digits live in the caller's Tier 3 buffer (Spec B
// §5): this component holds none and never shows them.
import { Pressable, View } from "react-native";
import { Text } from "./Text";
import { useTheme } from "./theme";

const KEYS = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "del"] as const;

export type PinPadProps = { value: string; onChange: (next: string) => void; length?: number; label: string; testID?: string };

export function PinPad({ value, onChange, length = 4, label, testID }: PinPadProps) {
  const t = useTheme();
  const press = (k: (typeof KEYS)[number]) => {
    if (k === "del") onChange(value.slice(0, -1));
    else if (k && value.length < length) onChange(value + k);
  };
  return (
    <View testID={testID} style={{ gap: 16 }} className="items-center">
      <Text variant="label">{label}</Text>
      <View className="flex-row" style={{ gap: 16 }} accessibilityLabel={`${value.length} of ${length} digits entered`}>
        {Array.from({ length }, (_, i) => (
          <View
            key={i}
            className={`h-4 w-4 rounded-full border-2 border-control ${i < value.length ? "bg-action-strong" : "bg-surface"}`}
          />
        ))}
      </View>
      <View className="flex-row flex-wrap justify-center" style={{ width: 3 * 72 + 2 * 12, gap: 12 }}>
        {KEYS.map((k, i) =>
          k === "" ? (
            <View key={i} style={{ width: 72, height: Math.max(56, t.metrics.minTouch) }} />
          ) : (
            <Pressable
              key={i}
              accessibilityRole="button"
              accessibilityLabel={k === "del" ? "Delete" : k}
              onPress={() => press(k)}
              className="items-center justify-center rounded-lg border border-control bg-surface"
              style={{ width: 72, height: Math.max(56, t.metrics.minTouch) }}
            >
              <Text variant="title" tabular>
                {k === "del" ? "⌫" : k}
              </Text>
            </Pressable>
          ),
        )}
      </View>
    </View>
  );
}
