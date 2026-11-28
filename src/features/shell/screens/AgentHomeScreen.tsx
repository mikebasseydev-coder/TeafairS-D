// A Monvelo agent member with no tenant (Spec B §9.3). Slice B3 builds the
// agent shell; until then this names the route and offers sign-out.
import { View } from "react-native";
import { useSignOut } from "@/features/auth";
import { Button, EmptyState, Screen } from "@/shared/ui";

export function AgentHomeScreen() {
  const out = useSignOut();
  return (
    <Screen testID="agent-home">
      <View style={{ gap: 24, width: "100%", maxWidth: 440, alignSelf: "center", paddingTop: 32 }}>
        <EmptyState title="Monvelo agent" message="Your offers, pledges and fundings arrive with the next release." emblem />
        <Button label="Sign out" variant="secondary" onPress={() => void out.signOut()} busy={out.busy} testID="sign-out" />
      </View>
    </Screen>
  );
}
