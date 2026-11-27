import type { ReactNode } from "react";
import { View } from "react-native";

/** A surface with a hairline border: no shadow, no blur (Spec B §4.1). */
export function Card({ children, testID }: { children: ReactNode; testID?: string }) {
  return (
    <View testID={testID} className="rounded-lg border border-hairline bg-surface p-4" style={{ gap: 8 }}>
      {children}
    </View>
  );
}
