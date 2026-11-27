// A 6-digit code entry over one hidden input, so paste and the OS one-time-
// code autofill work. The value is the caller's Tier 3 buffer.
import { useRef, type ComponentRef } from "react";
import { Pressable, TextInput, View } from "react-native";
import { Text } from "./Text";

export type OtpInputProps = { value: string; onChange: (next: string) => void; length?: number; label: string; testID?: string };

export function OtpInput({ value, onChange, length = 6, label, testID }: OtpInputProps) {
  const input = useRef<ComponentRef<typeof TextInput>>(null);
  return (
    <View style={{ gap: 6 }} testID={testID}>
      <Text variant="label">{label}</Text>
      <Pressable onPress={() => input.current?.focus()} accessibilityRole="none" className="flex-row" style={{ gap: 8 }}>
        {Array.from({ length }, (_, i) => (
          <View
            key={i}
            className={`items-center justify-center rounded-lg bg-surface ${i === value.length ? "border-2 border-focus" : "border border-control"}`}
            style={{ width: 44, height: 52 }}
          >
            <Text variant="title" tabular>
              {value[i] ?? ""}
            </Text>
          </View>
        ))}
      </Pressable>
      <TextInput
        ref={input}
        value={value}
        onChangeText={(t) => onChange(t.replace(/\D/g, "").slice(0, length))}
        keyboardType="number-pad"
        textContentType="oneTimeCode"
        autoComplete="one-time-code"
        maxLength={length}
        accessibilityLabel={label}
        style={{ position: "absolute", opacity: 0, width: 1, height: 1 }}
      />
    </View>
  );
}
