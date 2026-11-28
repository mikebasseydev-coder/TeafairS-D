// Onboarding (Spec B §9.3): the person's invitations, accepted or declined.
import { View } from "react-native";
import { Banner, Screen, SkeletonList, Text } from "@/shared/ui";
import { InvitationCard } from "../components/InvitationCard";
import { useInvitations } from "../hooks/use-invitations";

export function OnboardingScreen() {
  const inv = useInvitations();
  return (
    <Screen testID="onboarding">
      <View style={{ gap: 16, width: "100%", maxWidth: 560, alignSelf: "center" }}>
        <Text variant="title">Your invitations</Text>
        <Text color="muted">Accept to join the team. You set a PIN for each team you join.</Text>
        {inv.failure ? <Banner tone="danger" title={inv.failure} testID="invitation-failure" /> : null}
        {inv.loadError ? <Banner tone="danger" title={inv.loadError} /> : null}
        {inv.loading && inv.items.length === 0 ? <SkeletonList rows={2} /> : null}
        {inv.items.map((i) => (
          <InvitationCard
            key={i.tenant_user_id}
            invitation={i}
            busy={inv.busyId === i.tenant_user_id}
            disabled={inv.busyId !== null}
            onAccept={() => void inv.accept(i.tenant_user_id)}
            onDecline={() => void inv.decline(i.tenant_user_id)}
          />
        ))}
      </View>
    </Screen>
  );
}
