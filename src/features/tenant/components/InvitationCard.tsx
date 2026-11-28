import { View } from "react-native";
import { Button, Card, Text } from "@/shared/ui";
import type { Invitation } from "../types";
import { ROLE_LABEL } from "./role-label";

export type InvitationCardProps = {
  invitation: Invitation;
  busy: boolean;
  disabled: boolean;
  onAccept: () => void;
  onDecline: () => void;
};

export function InvitationCard({ invitation: i, busy, disabled, onAccept, onDecline }: InvitationCardProps) {
  const place = [i.area_name, i.territory_name, i.zone_name].filter(Boolean).join(", ");
  return (
    <Card testID={`invitation-${i.tenant_code}`}>
      <Text variant="heading">{i.tenant_name}</Text>
      <Text color="muted" variant="label">
        {i.tenant_code}
      </Text>
      <Text>{ROLE_LABEL[i.role]}</Text>
      {place ? <Text color="muted">{place}</Text> : null}
      <View className="flex-row" style={{ gap: 12, marginTop: 8 }}>
        <View style={{ flex: 1 }}>
          <Button label="Accept" onPress={onAccept} busy={busy} disabled={disabled} testID="invitation-accept" />
        </View>
        <View style={{ flex: 1 }}>
          <Button label="Decline" variant="secondary" onPress={onDecline} disabled={disabled} testID="invitation-decline" />
        </View>
      </View>
    </Card>
  );
}
