// A status in words, an icon and a tone; there is no colour-only variant
// (Spec B §4.2). Each tone's classes are written out so NativeWind sees them.
import { View } from "react-native";
import type { SemanticTone } from "@/shared/tokens";
import { Text } from "./Text";
import { ToneIcon } from "./ToneIcon";
import { useTheme } from "./theme";

export const TONE_CLASSES: Record<SemanticTone, { box: string; text: string }> = {
  neutral: { box: "bg-tone-neutral-subtle border-tone-neutral", text: "text-tone-neutral" },
  brand: { box: "bg-tone-brand-subtle border-tone-brand", text: "text-tone-brand" },
  success: { box: "bg-tone-success-subtle border-tone-success", text: "text-tone-success" },
  warning: { box: "bg-tone-warning-subtle border-tone-warning", text: "text-tone-warning" },
  danger: { box: "bg-tone-danger-subtle border-tone-danger", text: "text-tone-danger" },
  info: { box: "bg-tone-info-subtle border-tone-info", text: "text-tone-info" },
  pending: { box: "bg-tone-pending-subtle border-tone-pending", text: "text-tone-pending" },
};

export type BadgeProps = { tone: SemanticTone; label: string; testID?: string };

export function Badge({ tone, label, testID }: BadgeProps) {
  const { metrics } = useTheme();
  const c = TONE_CLASSES[tone];
  return (
    <View
      testID={testID}
      accessibilityRole="text"
      accessibilityLabel={label}
      className={`flex-row items-center self-start rounded-full px-2 py-0.5 ${c.box}`}
      style={{ borderWidth: metrics.badgeBorder, gap: 4 }}
    >
      <ToneIcon tone={tone} size={14} />
      <Text variant="caption" className={`font-semibold ${c.text}`}>
        {label}
      </Text>
    </View>
  );
}
