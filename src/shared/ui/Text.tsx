// The Swiss type scale (Spec B §4.1): 12, 14, 16, 20, 24, 32, the platform
// system font, hierarchy from size and weight.
import { Text as RNText, type TextProps } from "react-native";

export type TextVariant = "display" | "title" | "heading" | "body" | "label" | "caption";
export type TextColor = "ink" | "muted" | "on-action" | "on-action-strong";

const VARIANT: Record<TextVariant, string> = {
  display: "text-2xl font-bold",
  title: "text-xl font-semibold",
  heading: "text-lg font-semibold",
  body: "text-base",
  label: "text-sm font-semibold",
  caption: "text-xs",
};

const COLOR: Record<TextColor, string> = {
  ink: "text-ink",
  muted: "text-ink-muted",
  "on-action": "text-on-action",
  "on-action-strong": "text-on-action-strong",
};

export type AppTextProps = TextProps & {
  variant?: TextVariant;
  color?: TextColor;
  /** Money and counts: tabular numerals. */
  tabular?: boolean;
  className?: string;
};

export function Text({ variant = "body", color = "ink", tabular, className, style, ...rest }: AppTextProps) {
  return (
    <RNText
      {...rest}
      className={`${VARIANT[variant]} ${COLOR[color]} ${className ?? ""}`}
      style={[tabular ? { fontVariant: ["tabular-nums"] } : null, style]}
    />
  );
}
