import { Pressable, View } from "react-native";
import { Badge, type BadgeProps } from "./Badge";
import { LIST_ROW_HEIGHT } from "./sizes";
import { Text } from "./Text";

export type ListRowProps = {
  title: string;
  subtitle?: string;
  /** Right-aligned figure, e.g. an amount: tabular numerals. */
  meta?: string;
  badge?: Pick<BadgeProps, "tone" | "label">;
  onPress?: () => void;
  testID?: string;
};

export function ListRow({ title, subtitle, meta, badge, onPress, testID }: ListRowProps) {
  return (
    <Pressable
      testID={testID}
      disabled={!onPress}
      onPress={onPress}
      accessibilityRole={onPress ? "button" : undefined}
      className="flex-row items-center border-b border-hairline bg-surface px-4"
      style={{ height: LIST_ROW_HEIGHT, gap: 12 }}
    >
      <View className="flex-1" style={{ gap: 2 }}>
        <Text variant="body" className="font-semibold" numberOfLines={1}>
          {title}
        </Text>
        {subtitle ? (
          <Text variant="caption" color="muted" numberOfLines={1}>
            {subtitle}
          </Text>
        ) : null}
      </View>
      <View className="items-end" style={{ gap: 4 }}>
        {meta ? (
          <Text variant="body" tabular>
            {meta}
          </Text>
        ) : null}
        {badge ? <Badge tone={badge.tone} label={badge.label} /> : null}
      </View>
    </Pressable>
  );
}
