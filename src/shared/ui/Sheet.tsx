import type { ReactNode } from "react";
import { Modal, Pressable, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { Text } from "./Text";

export type SheetProps = { visible: boolean; onClose: () => void; title: string; children: ReactNode; testID?: string };

/** A bottom sheet over the scrim. The scrim is the only translucent layer in the app. */
export function Sheet({ visible, onClose, title, children, testID }: SheetProps) {
  const insets = useSafeAreaInsets();
  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable accessibilityLabel="Close" onPress={onClose} className="flex-1 bg-scrim" />
      <View
        testID={testID}
        className="rounded-t-2xl border-t border-hairline bg-surface px-4 pt-4"
        style={{ paddingBottom: Math.max(16, insets.bottom), gap: 12 }}
      >
        <View className="flex-row items-center justify-between">
          <Text variant="heading" accessibilityRole="header">
            {title}
          </Text>
          <Pressable accessibilityRole="button" onPress={onClose} hitSlop={12} className="py-2">
            <Text variant="label">Close</Text>
          </Pressable>
        </View>
        {children}
      </View>
    </Modal>
  );
}
