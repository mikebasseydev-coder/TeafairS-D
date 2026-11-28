// The two dead ends of Spec B §9.3: no access yet, and platform staff (who
// work in TeafairWeb). Empty states are a brand moment, so the emblem shows.
import { View } from "react-native";
import { Button, EmptyState, Screen } from "@/shared/ui";

const COPY = {
  "no-access": {
    title: "No access yet",
    message: "You are signed in, but no team has given you access. Ask your manager to invite this email.",
  },
  "use-web": {
    title: "Use TeafairWeb",
    message: "Your work is in TeafairWeb, the admin portal. This app is for field, logistics, shop and agent work.",
  },
} as const;

export function AccessStateScreen({ kind, onSignOut, signingOut }: { kind: keyof typeof COPY; onSignOut: () => void; signingOut: boolean }) {
  const c = COPY[kind];
  return (
    <Screen testID={`access-${kind}`}>
      <View style={{ gap: 24, width: "100%", maxWidth: 440, alignSelf: "center", paddingTop: 32 }}>
        <EmptyState title={c.title} message={c.message} emblem />
        <Button label="Sign out" variant="secondary" onPress={onSignOut} busy={signingOut} testID="sign-out" />
      </View>
    </Screen>
  );
}
