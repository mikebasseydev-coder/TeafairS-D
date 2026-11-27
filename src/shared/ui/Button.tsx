// The default primary button is action-strong (botanical, white label 13.13:1).
// A spinner appears only inside a pressed button while its write is in flight
// (Spec B §4.3).
import { ActivityIndicator, Pressable, View } from "react-native";
import { Text, type TextColor } from "./Text";
import { useTheme } from "./theme";

export type ButtonVariant = "primary" | "accent" | "secondary";

const BOX: Record<ButtonVariant, string> = {
  primary: "bg-action-strong",
  accent: "bg-action",
  secondary: "bg-surface border border-control",
};
const LABEL: Record<ButtonVariant, TextColor> = { primary: "on-action-strong", accent: "on-action", secondary: "ink" };

export type ButtonProps = {
  label: string;
  onPress?: () => void;
  variant?: ButtonVariant;
  busy?: boolean;
  disabled?: boolean;
  testID?: string;
};

export function Button({ label, onPress, variant = "primary", busy, disabled, testID }: ButtonProps) {
  const t = useTheme();
  const inert = disabled || busy;
  const spinner = variant === "primary" ? t.colors["on-action-strong"] : variant === "accent" ? t.colors["on-action"] : t.colors.ink;
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      accessibilityLabel={label}
      accessibilityState={{ disabled: !!inert, busy: !!busy }}
      disabled={inert}
      onPress={onPress}
      className={`items-center justify-center rounded-lg px-4 ${BOX[variant]} ${disabled ? "opacity-50" : ""}`}
      style={{ minHeight: Math.max(48, t.metrics.minTouch) }}
    >
      <View className="flex-row items-center" style={{ gap: 8 }}>
        {busy ? <ActivityIndicator size="small" color={spinner} /> : null}
        <Text variant="label" color={LABEL[variant]} className="text-base">
          {label}
        </Text>
      </View>
    </Pressable>
  );
}
