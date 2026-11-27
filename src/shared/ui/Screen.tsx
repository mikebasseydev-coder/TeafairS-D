// A screen body inside the safe area (notch, dynamic island, nav bars).
import type { ReactNode } from "react";
import { ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

export function Screen({ children, testID, scroll = true }: { children: ReactNode; testID?: string; scroll?: boolean }) {
  const insets = useSafeAreaInsets();
  const pad = { paddingTop: insets.top + 16, paddingBottom: insets.bottom + 24, paddingLeft: insets.left + 16, paddingRight: insets.right + 16 };
  if (!scroll)
    return (
      <View testID={testID} className="flex-1 bg-canvas" style={pad}>
        {children}
      </View>
    );
  return (
    <ScrollView testID={testID} className="flex-1 bg-canvas" contentContainerStyle={[pad, { gap: 24 }]}>
      {children}
    </ScrollView>
  );
}
