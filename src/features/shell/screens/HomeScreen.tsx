// The B2 landing after the PIN gate. Slice B3 replaces it with the role
// shells of Spec B §10; until then it names the person, the team and the role,
// and holds the account actions.
import { View } from "react-native";
import { useSignOut } from "@/features/auth";
import { ROLE_LABEL, useActiveMembership } from "@/features/tenant";
import { Button, Card, Emblem, Screen, Text } from "@/shared/ui";
import { ThemeChoice } from "../components/ThemeChoice";
import { useThemeChoice } from "../hooks/use-theme-choice";

export function HomeScreen({ onChangePin }: { onChangePin: () => void }) {
  const membership = useActiveMembership();
  const theme = useThemeChoice();
  const out = useSignOut();
  return (
    <Screen testID="home">
      <View style={{ gap: 16, width: "100%", maxWidth: 560, alignSelf: "center" }}>
        <View className="flex-row items-center" style={{ gap: 12 }}>
          <Emblem size={32} />
          <Text variant="title" testID="home-tenant">
            {membership?.name ?? "Your team"}
          </Text>
        </View>
        <Card>
          <Text variant="label">Signed in as</Text>
          <Text testID="home-role">{membership ? ROLE_LABEL[membership.role] : "Team member"}</Text>
          <Text color="muted">Your workspace arrives with the next release.</Text>
        </Card>
        <ThemeChoice choice={theme.choice} roleDefault={theme.roleDefault} onChoose={(t) => (t ? theme.setTheme(t) : theme.clearTheme())} />
        <Button label="Change PIN" variant="secondary" onPress={onChangePin} testID="home-change-pin" />
        <Button label="Sign out" variant="secondary" onPress={() => void out.signOut()} busy={out.busy} testID="sign-out" />
      </View>
    </Screen>
  );
}
