import { Pressable, View } from "react-native";
import type { SemanticTone } from "@/shared/tokens";
import { TONE_CLASSES } from "./Badge";
import { Text } from "./Text";
import { ToneIcon } from "./ToneIcon";

export type BannerProps = {
  tone: SemanticTone;
  title: string;
  message?: string;
  action?: { label: string; onPress: () => void };
  testID?: string;
};

export function Banner({ tone, title, message, action, testID }: BannerProps) {
  const c = TONE_CLASSES[tone];
  return (
    <View
      testID={testID}
      accessibilityRole={tone === "danger" || tone === "warning" ? "alert" : undefined}
      className={`flex-row rounded-lg border p-3 ${c.box}`}
      style={{ gap: 12 }}
    >
      <View className="pt-0.5">
        <ToneIcon tone={tone} size={20} />
      </View>
      <View className="flex-1" style={{ gap: 4 }}>
        <Text variant="label" className={c.text}>
          {title}
        </Text>
        {message ? <Text variant="body">{message}</Text> : null}
        {action ? (
          <Pressable accessibilityRole="button" onPress={action.onPress} className="self-start py-2" hitSlop={8}>
            <Text variant="label" className="underline">
              {action.label}
            </Text>
          </Pressable>
        ) : null}
      </View>
    </View>
  );
}
