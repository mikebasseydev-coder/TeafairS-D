// A labelled input. Its boundary is `control` (3:1), never the hairline.
import { useState } from "react";
import { TextInput, View, type TextInputProps } from "react-native";
import { Text } from "./Text";
import { ToneIcon } from "./ToneIcon";
import { useTheme } from "./theme";

export type FieldProps = Omit<TextInputProps, "style" | "className"> & {
  label: string;
  hint?: string;
  error?: string;
};

export function Field({ label, hint, error, testID, ...input }: FieldProps) {
  const t = useTheme();
  const [focused, setFocused] = useState(false);
  const border = error ? "border-tone-danger" : focused ? "border-focus" : "border-control";
  return (
    <View style={{ gap: 6 }} testID={testID}>
      <Text variant="label">{label}</Text>
      <TextInput
        {...input}
        accessibilityLabel={label}
        accessibilityHint={hint}
        placeholderTextColor={t.colors["ink-muted"]}
        onFocus={(e) => {
          setFocused(true);
          input.onFocus?.(e);
        }}
        onBlur={(e) => {
          setFocused(false);
          input.onBlur?.(e);
        }}
        className={`rounded-lg bg-surface px-3 text-base text-ink ${border}`}
        style={{ minHeight: 48, borderWidth: focused ? t.metrics.focusRing : 1 }}
      />
      {error ? (
        <View className="flex-row items-center" style={{ gap: 6 }}>
          <ToneIcon tone="danger" size={14} />
          <Text variant="caption" className="text-tone-danger">
            {error}
          </Text>
        </View>
      ) : hint ? (
        <Text variant="caption" color="muted">
          {hint}
        </Text>
      ) : null}
    </View>
  );
}
