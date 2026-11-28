// The theme choice (Spec B §4.2): a saved choice wins in every tenant;
// "Role default" clears it.
import { Pressable, View } from "react-native";
import { Text } from "@/shared/ui";
import type { ThemeName } from "@/shared/tokens";

const OPTIONS: { value: ThemeName | null; label: string }[] = [
  { value: null, label: "Role default" },
  { value: "standard", label: "Standard" },
  { value: "daylight", label: "Daylight" },
  { value: "dark", label: "Dark" },
];

export type ThemeChoiceProps = { choice: ThemeName | null; roleDefault: ThemeName; onChoose: (t: ThemeName | null) => void };

export function ThemeChoice({ choice, roleDefault, onChoose }: ThemeChoiceProps) {
  return (
    <View style={{ gap: 8 }} testID="theme-choice">
      <Text variant="label">Theme</Text>
      <View className="flex-row flex-wrap" style={{ gap: 8 }} accessibilityRole="radiogroup">
        {OPTIONS.map((o) => {
          const selected = o.value === choice;
          const label = o.value === null ? `${o.label} (${roleDefault})` : o.label;
          return (
            <Pressable
              key={o.label}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              accessibilityLabel={label}
              onPress={() => onChoose(o.value)}
              className={`items-center justify-center rounded-lg px-4 ${selected ? "border-2 border-focus bg-surface" : "border border-control bg-surface"}`}
              style={{ minHeight: 48 }}
              testID={`theme-${o.value ?? "default"}`}
            >
              <Text variant="label">{label}</Text>
            </Pressable>
          );
        })}
      </View>
    </View>
  );
}
