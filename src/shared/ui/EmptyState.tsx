import { View } from "react-native";
import { Button } from "./Button";
import { Emblem } from "./Emblem";
import { Text } from "./Text";

export type EmptyStateProps = {
  title: string;
  message: string;
  action?: { label: string; onPress: () => void };
  /** Empty states are a brand moment: the emblem may appear (Spec B §4.1). */
  emblem?: boolean;
  testID?: string;
};

export function EmptyState({ title, message, action, emblem, testID }: EmptyStateProps) {
  return (
    <View testID={testID} className="items-center justify-center px-6 py-8" style={{ gap: 12 }}>
      {emblem ? <Emblem size={64} /> : null}
      <Text variant="heading" className="text-center">
        {title}
      </Text>
      <Text variant="body" color="muted" className="text-center">
        {message}
      </Text>
      {action ? <Button variant="secondary" label={action.label} onPress={action.onPress} /> : null}
    </View>
  );
}
